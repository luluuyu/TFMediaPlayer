1. 找不到FFmpeg的函数符号，因为在c++文件里导入，使用c++的方式链接，而FFmpeg是c函数符号。使用`extern "C"`

2. 编译优化：
 * [一个参考](https://gist.github.com/lulalala/7028049)
 * `Invalid data found when processing input`缺少了demuxer
 * `av_strerror `解析错误

3. 音频播放：
 * 音频和视频的驱动点不同，流动方式不同。视频是数据源**主动**的推送数据，并且是离散的一帧帧明确分开的，而音频是系统播放器主动拉取数据，也就是数据源**被动**输出数据，并且音频是连续的，传递给系统的时间，并不是这一帧的播放时间，它更像是一个**时间段**，而不是点。
 * 格式信息在stream的codecpar(AVCodecParameters类型)里，不需要等得到AVFrame的时候再去获取格式信息。
 * 问题：音频在文件或传输中都是编码后的类型，是什么决定它解码后是什么类型？是在原数据中就携带了，还是在解码过程中可选的呢？
 * 格式转换添加planar，也就是声道数据分开。audioUnit的填充audio buffer的方法也要稍微修改，传入uint8_t**,即指针的指针，以及planar数量。
 * 构建audioUnit的音频格式，使用系统提供的`FillOutASBDForLPCM`更方便
 * 音频的解码是一个packet对应多个frame.
 * 音频的linesize只要第一个有效，因为每个linesize强制一样。
 * FFmpeg的linesize单位是byte.
 * 奇怪的是`AV_SAMPLE_FMT_FLTP`格式，linesize为8192,nb_samples为1024，算起来bitPerSample为8.
 * `av_frame_clone`返回为null，如果src不是ref的话。
 * **audioUnit音频不能阻塞**，线程卡住会导致最后的声音片段重复，非常不好。在音频framebuffer为空或暂停播放的时候，填充空数据，也即是把要传递的buffer剩余部分全部置为0。
 

4. 音视频同步
 * 使用remainTime，如果计算失误，会导致sleep非常长时间。
 * 如果音频消耗慢，视频消耗快，那么音频会越来越多，直到音频缓冲区满了，这时如果解析到一个音频packet，那么就会一直等待音频缓冲区有空间。而视频那边还在不断播放，直到视频空了。可能出现奇怪问题。**但是正常解析应该不会出现这样的情况**
 * 针对上述问题：1.具体怎么死锁？ 2.是否动态扩展缓冲区的limit来避免此类问题？
 * 并没有死锁，是播放器停止了，但是没停止音频播放器。上述情况应该可以不处理
 
 
5. 缓冲区
 * 一个隐患是不同流使用的是同一个获取线程，如果某个流满了，难么所有流的获取都要停滞。比如音频packet缓冲区满了，但是视频缓冲区还缺少，这时不解析packet了，视频获取不了，播不下去，那么音频就不会减少，然后又返回来继续阻塞，然后整个流程就死了。
 * 核心问题是音频packet和视频packet的数量对比，还有frame。他们可能不是1：1的。
 * 释放资源逻辑：先把阻塞的释放，但是不做任何的node插入和取出，不改变已有的数据，对于输入，还会把插入的这一个node释放掉。从这开始，内部的数据不会发生任何改变，而且也不会阻塞外界的操作。这样就把内外

6. 音频的重采样
 * resample的参数是channel_layout，而不是channels，修改channels而没有修改channel_layout，导致不匹配错误。
 * `swr_convert`的输入和输出都是针对perChannel的

 
7. 哒哒声的问题：
  >今天刚好碰到同样的问题，google, baidu均无解，无奈自己研究，是因为语音数据里包含了RTP包头的原因，自己写了个转换工具，把12Bytes的RTP包头去掉，哒哒声就没了
  
  * 哒哒声是因为突然的数值变大，导致音爆。很可能是数据读取位置错误，导致读数错误。而且每次解码同一个音频的数据也不同，很奇怪
  * 第一步： 修改swr resample的方法
  * nb_samples的计算有很多值得深究，`swr_get_delay`是干嘛的？`swr_get_out_samples`有没有用？`nb_samples`到底是不是单个channel的？
  * resample修改后，数据变稳定了，虽然还是坏的。稳定原因可能是nb_samples的问题，之前可能是不固定的，待查。
  * 第二步：使用s16的纯pcm音频来播放，仍然存在问题。排除是resample的问题。
  * 查看声波图，数据稳定、分散、空白较多。听起来，速度加快了，但原节奏基本在。速度加快这一条可以先查。
  * 使用`av_fast_malloc`和一个固定的内存来保留读取时遗留的一段buffer.`av_fast_malloc`第二个参数在成功是可能不等于第三个参数，有效的遗留buffer长度不能根据第二个参数的返回值来。
  * s16单声道pcm播放没问题了，问题出在读取音频buffer的时候，读了buffer,而不是buffer[i]。**内存相关处理里，这个点是非常危险的，而且是很容易出错的，把指针的指针传给指针，编译器是区分不出来的**
  * 还需要检查之前的代码是否也是这个问题，还有AAC播放是否可以了。
  * 带视频的双声道音频AAC还是杂音，纯音频AAC可以了，第一个sampleRate是48k,第二个是44.1k。码率不同，而且不是倍数，很可能造成错位问题。
  * 11.025k的MP3格式播放基本没问题，高音处会有杂音，有点像数值溢出。
  * game视频播放已经没有音爆了，说明之前的代码也是有上述问题，就是buffer读错了。现在的问题是变音了，像扭曲了一样，但是真个的节奏都在，声音没丢。` memcpy(buffer, dataBuffer, needReadSize);`错误就是这句，一直在。
  * 重大突破：使用audioQueue，把sampleRate设为和音频源一致，然后每次的size也和resample之后每帧一致，一点杂音都没有。**resample和读取可能都有问题，错位的感觉**
 * 把queueBuffer的samples调整到2048,出现后半截就是空值。
 * **问题找到了，跟resample没关系，还是我代码写错了，拷贝buffer的时候，没有考虑到可能已经拷贝了一段内存，所以后面的会覆盖前面的内存，导致后面的内存空掉**
 * **有价值的是：那些莎莎声，都是丢失的数据，也就是空白**这也和为什么电脑卡顿之类的情况时，会有莎莎声。运行不流畅，数据没有接上，导致数据空白。


8. 视频播放
 * 图像出现错位、扭曲，这个不好描述，有点像衣服扣子系错了的感觉。就是层和层之间的错位。[有可能是这里描述的问题](http://blog.csdn.net/grafx/article/details/29185147)
 * 宽度是568，但linesize是576.这个两个值不同，有8个字节是无用的。
 * 如果把播放宽度设为linesize,那么播放画面正常，但是结尾是绿色，就是没有数据。
 * 每个plane的数据是连续的，但是显示到界面上是2维的，也就是要切割成n段，每段是屏幕上的一行。而linesize就是每一段的长度，影响着从哪里切开的问题。上面的问题就是使用width当做linesize,而width<linesize,导致切割的地方短了，剩余的部分流到了下一层，把下一层往后挤，导致层层错位。
 * **构建texture同时需要width和linesize,width决定哪些数据时有效的，linesize决定每一行的数据怎么划分**
 * [texture对齐和裁剪](http://www.zwqxin.com/archives/opengl/opengl-api-memorandum-2.html)
 * 使用`glPixelStorei(GL_UNPACK_ROW_LENGTH, linesize[0]);`来形成裁剪后的图像，避开结尾无用的数据。
 * 底部还是有绿色，说明还是有空数据，高度有问题？texture的高度是240

 
9. 内存释放
 * 缓冲池里的视频frame数据无法释放。
 * 可以确定不是音频的问题；跟缓冲区的大小密切相关；跟播放部分无关。
 * 有一点可以确定，缓冲区留存的可用数据越多，内存泄漏越多.
 * 突破的一点是:数据存在frame的buf内，而buf通过`av_buffer_unref`释放，
 
   ```
  void av_buffer_unref(AVBufferRef **buf)
{
    if (!buf || !*buf)
        return;

    buffer_replace(buf, NULL);
}

 static void buffer_replace(AVBufferRef **dst, AVBufferRef **src)
{
    AVBuffer *b;

    b = (*dst)->buffer;

    if (src) {
        **dst = **src;
        av_freep(src);
    } else
        av_freep(dst);

    if (atomic_fetch_add_explicit(&b->refcount, -1, memory_order_acq_rel) == 1) {
        b->free(b->opaque, b->data);
        av_freep(&b);
    }
}
 ```
 
 关键在于：`atomic_fetch_add_explicit(&b->refcount, -1, memory_order_acq_rel) == 1`条件成立，才会释放资源。`std::atomic_uint refcount;`这个是refcount的类型，即`atomic<unsigned int>`，也就是模板类型是`unsigned int`，但是传入的值却是-1,是这里的有问题？**这里没有问题**虽然转义了，但本质上的值是没变的，变量类型只是用来识别的方式不同，在硬件上的二进制形式是没变的。
 
 * 调用了`b->free`但却没有释放内存，这个函数本质是`pool_release_buffer`.
 * 这里使用了`AVBufferPool`来管理内存,buffer的引用为0后不是立即销毁，而是回到pool里，重复使用。调用`av_buffer_pool_uninit`标记为可释放，然后到pool里所有的buffer都回归了，才倾倒pool.**为了避免频繁大量的内存分配和释放**
 * 所以问题指向了pool为什么没有释放。
 * 更奇怪的是pool的refcount为0，而且存储实际buffer的链表pool为空，也就是说buffer的pool是空的，但是它的free方法还是`pool_release_buffer`，也许构建的时候出错了？
 * pool是对的，打印的地址和`video_get_buffer`时使用的一致，来源是`FramePool *pool = AVCodecContext->internal->pool;`
 * 使用pool最初构建的frame不是最后取出来的frame，需要查frame从哪来的.需要检查receive_frame的路线：
 
     ```
     avcodec_receive_frame
     av_frame_move_ref(frame, avci->buffer_frame);
     ```
     p来源于`AVCodecContext->internal->thread_ctx->threads[i];`
     
     codecContext获取frame的路线：
     
      ```
      avcodec_send_packet
      ret = decode_receive_frame_internal(avctx, avci->buffer_frame);
      decode_simple_receive_frame
      decode_simple_internal
      ret = avctx->codec->decode(avctx, frame, &got_frame, pkt);
      h264_decode_frame
      ....
     
      decode_nal_units
      ff_h264_queue_decode_slice
      h264_field_start
      h264_frame_start
      alloc_picture
     ff_thread_get_buffer
     thread_get_buffer_internal
     ff_get_buffer
     get_buffer_internal
     avctx->get_buffer2(avctx, frame, flags)
     avcodec_default_get_buffer2
     video_get_buffer
     av_buffer_pool_get pool分配buf内存
     ....
     finalize_frame
     ret = output_frame(h, dst, out);
     ret = av_frame_ref(dst, src);
     
     ```
     
     AVFrame->buf[i]是不同的，但是AVBuffer是相同的，AVFrame->buf[i]是AVBufferRef.
     ```
     Printing description of dst->buf[0]->buffer:
(AVBuffer *) buffer = 0x00000001013d2e40
Printing description of srcp->f->buf[0]->buffer:
(AVBuffer *) buffer = 0x00000001013d2e40
     ```
     内部的buf和外界取出来的buf一致，buf是指`AVFrame->buf[i]->buffer`
     
     **Xcode的bebug框可以使用View Value As->customType来使用新的类型查看数据，对于void*类型非常好**
     
     最后发现是tf_AVBufferPool类型错误，所以对pool的refcount读取错误以为是0，错误原因是`#define AVMutex pthread_mutex_t`，把`AVMutex`定义成了`char`，那是一个条件编译。
     
     然后pool的refcount就变得有规律了，从105降到了5，**所以是有些frame没有释放导致的。**
     
     有两个是解码失败，然后直接continue了，没有把frame释放。**这也是一个思维陷阱吧，内存管理上的概念**
   * 糟糕的是第一次接收frame的时候，pool的refcount就已经是4了，不知道分配到哪里去了，而且也只有两次是reveive失败的。
   * 第一次执行`avcodec_send_packet`就是2，应该是一个init和一个get_buffer，数组存了10个frame，然后有两次receive失败，buf没有释放，所以最后refcount到了13。在释放的时候10个buffer只有7个释放，所以最后多出了3个，结束pool的refcount变成6,因为pool存在，所以内部所有buffer都没释放。
   * 1. uninit没调用 2.失败的receive没有unref 3.有buffer在unref后没有free
   * AVBuffer是循环使用的，而且他们都是通过`av_buffer_create`构建的。所以通过这个函数的断点查看内外的buffer的关系。
   * 发现不管存几个frame，一定是最后一个和倒数第3个的buf没释放
   * unref frame的情况：
     * `h264_frame_start->ff_h264_unref_picture[504]`
     * `h264_field_start->h264_init_ps->av_buffer_unref`
     * `release_unused_pictures->ff_h264_unref_picture`
   * 然后`ff_h264_unref_picture`内部有：
     * `ff_thread_release_buffer->av_frame_unref`这里有4个buffer，YUV分3层，加一个private_buf
     * 其他6个`av_buffer_unref`
     * 所以总共10个buf释放。
   * frame取出来的时候里面buffer的refcount都是2，看来是之后才会释放。**问题可能出在直接的break而没有调用界面的环境销毁**。那些正常释放的确实是在之后的`release_unused_pictures`里释放的，但是这个函数只在下一帧解码的时候开始。
   * 所以找到了`h264_decode_end`，这里调用了释放操作，和`release_unused_pictures`里几乎一致。
   * 确认`h264_decode_end `在stop时候没调用，调用它的方式是`avctx->codec->close(avctx);`,对每个解码器是通用的，`close`指针指向了不同的函数。
   * 对于用户应该调用`avcodec_close`和`avformat_free_context`来释放资源。`avcodec_close`对应上面的`h264_decode_end`，确认没调用。`avcodec_free_context`在`libavcodec/options.c里`
   * 把freeResouces的一系列方法打开后，内存已经可以释放了，其实`avformat_free_context`内部回调用`avcodec_close`,**根本的问题实际是出在解码失败或frame没数据后直接continue,而没有调av_frame_free来释放，导致这些frame漏掉，而又实用了缓冲池，导致内存一个都没释放**。我改掉这个问题后，又没有把之前的freeResouces一系列方法再改回来，所以`avcodec_close `没调用，导致仍然有留存。
   * **使用缓冲池结构的东西，一定是随时保持着一定使用数量的，所以必须要有整体倾倒的方法**
   * 切换到自己设计的缓冲区还是有一些问题，停止播放的时候，把缓冲区的进出阻塞都解除，如果缓冲区满的，进入阻塞解除，那么就会有一个frame被新进来的覆盖，导致它丢失，在clear的时候没有把它free.
   * 在开始释放的时候，`blockInsert和blockGetOut`的阻塞解除，但是不把node插入或取出，而且对于insert，还要释放这个多余的node,因为只要insert进来的node,缓冲区就已经接管了它的内存管理。
   * `if (decoder->shouldDecode)`判断为NO时，也要释放frame.
   * **3个核心函数里只有`avcodec_receive_frame`是会自动调用unref的，`av_read_frame`并不会unref packet**
   * <<所以可以改为`av_read_frame`之后不释放，在进入packet缓冲区之前也不使用另一个packet来做ref,直接把原packet放进去，然后在最后使用完unref。>>**这样做是错的**，因为`av_read_frame`内部调用`read_frame_internal`到`av_init_packet`,会把buf设为null,导致之后的packet丢失了buf信息，没法释放。所以还是要自己引用ref到一个新的packet里，用来管理内存。

   
10. seek跳转播放

 * 第一步，seek之后清空缓冲区
 * seek之后花屏，[花屏问题参考](http://blog.csdn.net/matrix_laboratory/article/details/71757493).应该是需要seek到关键帧才行，否则当前帧会因为缺失关键帧而解码成奇怪的图像，形成花屏。
 * 修改`av_seek_frame`的最后一个参数，使得总是获取到关键帧。花屏问题没有了。
 * 播放卡死 
  
  卡死都是因为音视频的某条线路播放停止，导致这个流的缓冲区充满，导致读取线程卡死。因为不同流读取是同一个方法、同一个线程，读取出来之后才能确定是哪个流的数据，读取是在一起的。某个流卡死，会导致整体卡死。
  
  虽然有上述的致命问题，但是如果你保持好音视频同步，这个问题是不会发生的，因为如果不同流播放的时间一致，读取的时间一致(假设视频源是好的)，那么不同流缓冲区保存的量是相近的时间，就不可能一个流的缓冲区满了，而另一个空了。
  
  所以，虽然导致卡死的直接问题是缓冲区满了，但根本问题是没有处理好音视频同步问题。
  
 * 同步失败卡死
 
  视频不播放而导致视频缓冲区满了，为什么不播放？因为计算remainTime大大超出预期。如3s seek 到13s, 这时还是基于当前的时间基准计算，得出需要10s后播放这一帧，那么视频就卡死了。
  
  为什么会在seek之后还使用之前的计算基准？计算是按音频钟来算的，然后seek之后，缓冲区里还保留了之前的音频数据，播放了它，那么计算基准就调节成了这个数据的基准。**这个跟我音视频同步的手段有关系，我是按照数据的pts和现实时间差来计算下一帧的时间的**
  
  如pts为3的数据在现实时间103的时候播放，那么差值就是100，那么计算pts为50的数据，在现实时间150时候播放。
  
  而seek会打破原有的关系，比如pts为3之后立马seek到14，那么就是14的在现实104时候播放，差值是90。而如果保留了之前的数据，在14之前还播放了一个4，就把差值算成了100。等到14的时候，认为现实时间是114,那么就成了要等到10s了。
  
 * seek后遗留旧数据
  
  两个问题处理：1.调用`avcodec_flush_buffers`把解码器里的旧数据清空  2.缓冲区的flush操作，可能会有一个数据保存在**管道里**，就是在packet到frame的过程里，因为frame的缓冲区满了，它留在了**插入的过程里**，等到frame缓冲区flush结束候，它就跑进来了。所以要先清掉管道里的数据，再请池里的数据。
 
 * seek后视频数据优先，导致视频缓冲区会先满。因为seek了音频流，而因为视频关键帧的问题，视频会提前。为了能正常解码，必须从关键帧开始，seek到一个时间后，就往前跑找到第一个关键帧，如果关键帧间距大，seek的误差就很大。而音频不会有这个问题，音频比较准。

 采用seek音频，视频会偏移很多，而音频不会，那么两者差距就很大，而且因为前移，视频会提前多处许多数据，导致占满缓冲区。
 
 ```
 seek end! 46.472
 read frame[audio]: 1112064,50.434
 read frame[video]: 836000,46.444
 ```
 
 采用seek视频，视频仍然会偏移，但是音频会根据视频成功后的数据seek，这样虽然两者都偏移seek目标，但是音视频之间是同步的。
 
 ```
 seek end! 390.267
 read frame[audio]: 17100718,387.771
 read frame[video]: 6205984,387.874
 ```
 
* seek 不准的问题
  
  1.  丢弃packet读取是不可行的，会丢失i帧，导致解码失败，解码器会一直失败知道得到下一个i帧。这期间的数据都会丢失。
  2. 在播放端做控制，早于seek时间的frame丢弃，这时解码已经完成，丢弃不会影响。
  3. 在找到第一个时间大于seek时间的数据后，才结束seeking的状态，进度条在seeking过程中都显示为seek时间。

* seeking状态区间的最终方案

 需要准确的得到什么时候seek结束，才能控制进度条，在seeking里，进度条一直在用户自己拖动的位置，重新开始播放后，再按实际播放进度来算。结束的准确时刻是：清空之前的缓冲区，接入新的流之后，然后找到了第一个大于seek时间的数据。问题在于：这时仍然会有之前的数据遗留，如果是从后面seek到前面，那么遗留的数据一定大于seek time，导致立刻结束了seeking，实际还只是刚开始。
 
 方案就是使用播放时间来判定，而不是看这个数据是否通过，**通过**可能是在seek之前的条件下判断通过的。但播放时间不会错。
 
 **然后综合考虑，不把抓取seek结束数据的任务交给displayer**,在playController里加个线程，专门检测播放时间和seek time。比较方式采用靠近原则，即检测差值的绝对值。这样对于从后往前seek也是可行的。
 
 但要注意的是，这个是基于**seek之后开始的数据时早于seek time的**，如果一开始就大于，且超出范围，后面越来越大，就播放不了了。
 
#### 11. 暂停功能

 * 暂停时，媒体时间没变，而现实时间往前跑，所以两个时间线的对应关系被打破了，需要在播放开始时重新建立。
 * 暂停后，音频会暂时中断，直到ptsCorrection逐渐减小到之前的值，才恢复，很神奇。
 * ptsCorrection会逐渐减小是因为，音频填充的时间小于媒体的播放时间了。比如两个帧之间是0.05s，但是调用音频填充的间隔为0.02s，那么下一帧就会提前被填充，提供给系统，相当于提前播放了。问题就在于**为什么填充调用间隔提前了**。对于系统而言，是数据没了就来填充新的，如果每次填充的数据量是一样的，就不可能时间有变化。
 * **应该是sleep函数对系统的音频播放造成了破坏**，在暂停的时候，推入空数据的话就没什么问题了。但这样会有性能的浪费，最好上层播放器也暂停。
 * audioUnit的播放器暂停没有问题，audioQueue的暂停会消声。

### 12. 网络不够好的情况

最大的问题是**同步钟**会出错。因为卡顿，导致数据拿到的时候已经远远晚于它要播放的时间，按照原有逻辑，它们是要被丢弃的，这样会导致之后所有的数据都会被丢弃。

就需要引入正当的“缓冲”机制，缓冲是一种正常现象，要自动缓冲，缓冲结束重新构建同步钟。

有一件事可以确定，那就是**同步钟是一定要被多次重置的**


**问题**

 * seek的时候，audio和video都会快速的抛弃一些提前的数据，如果audio运行得比较快，那么audio很快就会空。然后判定为数据空，然后停止播放。然后video满了，然后又因为缓冲区加了一个下降到一般一下才解锁“满锁”，所以视频的满锁没解开，然后没法读取新的数据进来。

 即使把满锁去掉，也还是有问题。因为只会加一点的audio进来，然后播放还是不会恢复。
 
 关键问题在于：在video里有许多本该被丢弃的数据。**将seek后的数据检测，跟缓冲操作分开来**
 
 总结一下限制：
  
  1. packet缓冲区任何一个满了，会阻塞读取
  2. 缓冲区的“满锁”和“空锁”都是以一半为基准的
  3. seek之后要丢弃一部分的超前数据
  4. 缓冲区空了，会停止不放，满了才会恢复播放。

  核心限制是第一个，它的关键是：保证audio和video的frame buffer最新的一个是相近的时间。这样缓冲区内的个数是一致的，就能保证不会一个空
  
  
###总结下常见问题

1. 往后seek,音频有seek前残余，后面的视频计算出remainTime太长，视频缓冲区满，卡死。
 
2. 往前seek，视频有剩余，计算remainTime太长，视频缓冲区满，卡死。

  解决方案：
   * 首先保证整个流程没有旧的数据留存，音视频的frame buffer、packet buffer,decode函数里的临时变量，插入buffer时阻塞的临时变量，播放时的临时变量。
   * 然后使用过滤器把没到时间的frame直接丢弃，而不是到displayer才处理
   * 

3. seek过程最后是关闭播放，等待frame缓冲区满再打开播放，这个回调可能会插入到开始seek但还没有flush缓冲区的这个区间里，这样就会出错。简单说，这个过程里，缓冲区的数据是多线程公用的资源，需要互斥。
  
4. seek结束，打开播放到实际有一个audio播放出去之间是有一段间隔的，在这期间，currentTime是错误的。**这个不能忽视，比较明显**
5. seek开始声音卡顿、重复
  
  
###多种操作混合
  
###状态的维护

1. pause和loading是有共存的，在loading的时候pause,仍然保持loading，等到loading结束，要跳入playing的时候，要自动切换到pause。所以pause需要一个标记。这样两者就不会存在共存。或者loading加一个标记。具体再研究。
2. pause是用户的意图，这个是完全独立于媒体资源的状态的，所以必须单独标记。loading是一种状态，但不会是一种标记。标记代表着它独立存在，不受播放器自身状态影响。


###不同格式调试

1. flv的seek由问题。


###性能问题

1. 在解码时候，cpu大量消耗，然后会有一段时间的暂停。可能是缓冲区满了或者packet缓冲区没了，绝对的总量是没法降低的，但可以让解码过程更均匀的分布，也就是packet buffer的出和frame buffer的进不要设门槛，有一个就解一个。