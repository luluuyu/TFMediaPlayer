//
//  TFMPPlayCmdResolver.m
//  TFMediaPlayer
//
//  Created by shiwei on 2018/2/15.
//  Copyright © 2018年 shiwei. All rights reserved.
//

#import "TFMPPlayCmdResolver.h"
#import "TFMediaPlayer.h"

@interface TFMPPlayCmdResolver (){
    TFMPStateObserveHandler _observeHandler;
    NSArray *_observedStates;
    
    NSTimer *_stateTimer;
}

@end

@implementation TFMPPlayCmdResolver

-(void)setPlayer:(TFMediaPlayer *)player{
    _player = player;
    
    [[NSNotificationCenter defaultCenter]addObserver:self selector:@selector(playerStateChanged:) name:TFMPStateChangedNotification object:_player];
}

-(void)dealPlayControlCommand:(NSString *)command params:(NSDictionary<NSString *,id> *)params{
    if (_player == nil) {
        return;
    }
    
    if ([TFMPCmd_play isEqualToString:command]) {
        
    }else if ([TFMPCmd_pause isEqualToString:command]){
        
    }else if ([TFMPCmd_stop isEqualToString:command]){
        
    }else if ([TFMPCmd_seek_TD isEqualToString:command]){
        
        NSTimeInterval duration = [[params objectForKey:TFMPCmd_param_duration] doubleValue];
        [_player seekByForward:duration];
        
    }else if ([TFMPCmd_seek_TP isEqualToString:command]){
        
        NSTimeInterval time = [[params objectForKey:TFMPCmd_param_time] doubleValue];
        [_player seekToPlayTime:time];
        
    }else if ([TFMPCmd_fullScreen isEqualToString:command]){
        
        [_player changeFullScreenState];
    }
}

-(void)helpObserveStates:(NSArray<NSString *> *)states withChangedHandler:(TFMPStateObserveHandler)handler{
    
    if (states == nil || handler == nil) {
        return;
    }
    
    _observedStates = states;
    _observeHandler = handler;
    
    if ([states containsObject:TFMPState_currentTime]) {
        _stateTimer = [NSTimer timerWithTimeInterval:0.5 target:self selector:@selector(getPlayStates) userInfo:nil repeats:YES];
        
        [[NSRunLoop mainRunLoop] addTimer:_stateTimer forMode:NSRunLoopCommonModes];
    }
}

/** repeatly get all changing properties of player. */
-(void)getPlayStates{
    
    if ([_observedStates containsObject:TFMPState_currentTime]) {
        _observeHandler(TFMPState_currentTime, @(_player.currentTime));
    }
}

/** the changing of playing or pausing... */
-(void)playerStateChanged:(NSNotification *)notification{
    
    if (_player.state == TFMediaPlayerStateReady) {
        
        if ([_observedStates containsObject:TFMPState_duration] && _observeHandler) {
            _observeHandler(TFMPState_duration, @(_player.duration));
        }
    }
}

@end