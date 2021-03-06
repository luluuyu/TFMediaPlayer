重读ijk之后，有一些值得改进的东西，最主要的是serial的引用和同步钟的设计。

1. 同步的逻辑和ijk不一样，但是结果证明是一样的，而且我的更加简洁。
 * 避免后期问题，还是采用多个钟的方式，但计算使用之前方式。
 * 同步钟记录时精度问题也会造成数据丢失，注意`AV_TIME_BASE`是int

2. 获取当前媒体时间：seeking在一开始就重置了，距离正确开始播放还有一段时间，这之间怎么防止犯错的？出错就会产生进度条闪回的效果。
3. 内容不播的时候，时间还是往后走，因为时间是预测的、跟现实时间关联的，有漏洞。
4. `decoder_decode_frame`的代码还是有漏洞的，只是可能性比较小，如果serial的修改在`if (d->queue->serial == d->pkt_serial) {`这个判断之后，并且之后取frame一路顺畅，那么这个错误的frame会一直传入到frameQueue里面并且serial是新的。之所以没有出错，是在视频播放时`last_duration = vp_duration(is, lastvp, vp);`的计算里，使用了`if (isnan(duration) || duration <= 0 || duration > is->max_frame_duration)`的判断，返回seek的时候满足<=0,往前seek的时候满足`duration > is->max_frame_duration`。这时取得值是frame自身的duration，根据帧率计算的一个值，然后播放之后就一些重置了。
5. video_refresh里使用duration的好处是只跟上一帧比较，而不是直接的和同步钟的时间比较。
6. 第4点是错的`decoder_decode_frame `这个是没有漏洞的，因为读取到frame之后是break而不是return,还是要经过第二部分的serial检测。除非是已经返回的frame,这种概率就非常小了。再加上有duration把控，不会出错了。
7. 自己写的decode部分，frame去除来，这时这个frame可能对应的是之前的packet,所以在packet的分界点，**要全部重新开始，解码器里的、取出来的frame全部清空**
8. 缓冲区的设计可能有问题，packet读取出了刚插入的数据，可能在数据满了的时候，新插入的数据越过了边界，毕竟我没有加锁。然后decode那里应该没问题了，新的pts都是seek之后的。**没有加锁，in和out共享usedSize数据，用它来做判断后，情况可能被另一个线程修改了，再执行操作就错误了**
9. 加了锁之后，packet缓冲区读取没什么问题了，但是readFrame又开始卡住了。是因为读取到结尾，wait阻塞了。
10. 想要更准确的seek,需要：正常seek+时间筛选。正常seek会调到目标点以前，因为开始点必须是关键帧，关键帧间距越大这种效果越明显，然后正常解码，但是在播放时，把目标点之前的数据筛除掉。
11. seek带来的问题根本是seek之后打破原本的媒体时间和现实时间的关系，需要重新建立。而建立需要的新的数据而不是旧的数据，区分新旧就靠serial,但是因为多线程环境，还是会有问题。frame取出的时候做了判断，seek改变的那一点可能出现在frame取出判断到更新同步钟之间，这样一个旧的数据就以新的身份更新了同步钟。
12. 播放的时候，同步钟的serial和上一次更新的frame的serial一样，获取延迟的时候，也使用frame的serial跟同步钟的serial来做比较，总之是同步钟和frame之间的关系。不同的时候，代表到了临界点，延迟为0立马播放，这样就可以立即建立新的同步关系。
13. 在packetQueue很大时,还没播放结束，文件就已经读取完了，这时怎么处理播放？结束还是等待，如何等待以保证可以正确结束又可以再seek回去？结束+释放资源的问题还要重新处理。
14. 音频播放的延迟在最开始的时候，上层播放器的缓冲区是空的，延迟是0，这个就不再是固定的而是变动的，但是完全按变动的来处理又损失太大，因为只有最开始的2-3次是不确定的，后面都是固定的。
15. 将packet的serial传给frame,将frame的serial传给clock，这样就完全不用害怕多线程的问题了；前一步保证frame的serial一定是正确的，后一步保证不会使用错误的clock。**这一点真的是神器**
16. 内存管理：进来不播每次增长0.5M，播了在VTBSession那里增加0.3M。
17. `TFMediaPlayer`对象没释放,一开始的问题是playerController的lambda函数捕获引用了self,去掉后，进入页面不播放就可以释放了
18. 进入页面如果播放了，`TFMediaPlayer `还是没释放，最后找到`VTDecompressionSessionDecodeFrame`调用就不释放，不调用才会释放。完全看不出这两者之间的关系。而且跟解码回调函数无关。
19. 虽然不知道`VTDecompressionSessionDecodeFrame `是怎么影响结果的，但实际问题是stop的时候，在display loop里卡在了从frame缓冲区里取出据的那一步里，因为缓冲区空了。然后stop没有返回，导致self被GCD的block引用住，从而没有释放。
20. 也是神奇bug，终于明白为什么关闭硬解码会影响结果：
 
  * 关闭硬解码，视频处理速度非常快，一下就到底了，video loop会再第一次就卡在blockOut那里，因为一个frame都没有。在decoder stop的时候，会释放缓冲区的IO锁，这个时候video loop就会解开。
  * 在循环会来时，`checkingEnd`为true，且frame buffer都清空了，这时video loop就退出了。所以不会卡顿。
  * 而开启了解码，哪怕没有回调，速度也会变慢，所以退出的时候，文件还没读取结束，`checkingEnd`为NO,所以video loop还不会退出，在decode stop的时候，把frame buffer flush掉了，这时video loop就会进入blockGetOut的卡顿。最后结束不掉。

  总结：**我们看到一个东西匪夷所思的影响了另一个东西，很可能是因为这个东西要影响了第三者，第三者变化再转回来我们看到的结果，甚至可能有第4者、第5者，有一个长长的影响链。在这些东西里，有些是真的原因，有些只是绊脚石罢了。绊脚石不需要被修正，但它却可以帮助我们找到真的原因**