//
//  Steam+Audio.m
//  YPlayer
//
//Copytright(c) 2011 Hongbo Yang (hongbo@yang.me). All rights reserved
//This file is part of Steam.
//
//Steam is free software: you can redistribute it and/or modify
//it under the terms of the GNU Lesser General Public License as 
//published by the Free Software Foundation, either version 3 of 
//the License, or (at your option) any later version.
//
//Steam is distributed in the hope that it will be useful,
//but WITHOUT ANY WARRANTY; without even the implied warranty of
//MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//GNU Lesser General Public License for more details.
//
//You should have received a copy of the GNU Lesser General Public 
//License along with Steam.  If not, see <http://www.gnu.org/licenses/>.
//

#import "Steam+Audio.h"
#import "Steam+Private.h"
#import "Steam+Buffer.h"

#import "SteamHelper.h"

static const UInt32 kDefaultPacketBytesSize = 2048;
static const UInt32 kDefaultPacketNum = 256;

void myAudioQueueOutputCallback(
                                 void *                  inUserData,
                                 AudioQueueRef           inAQ,
                                 AudioQueueBufferRef     inBuffer);

void myAudioFileStreamPropertyListener(
                                             void *						inClientData,
                                             AudioFileStreamID			inAudioFileStream,
                                             AudioFileStreamPropertyID	inPropertyID,
                                             UInt32 *					ioFlags);

void myAudioFileStreamPackets(
                                 void *							inClientData,
                                 UInt32							inNumberBytes,
                                 UInt32							inNumberPackets,
                                 const void *					inInputData,
                                 AudioStreamPacketDescription	*inPacketDescriptions);

void myAudioQueuePropertyListenerProc(
                                       void *                  inUserData,
                                       AudioQueueRef           inAQ,
                                       AudioQueuePropertyID    inID);

void myAudioFileStreamPropertyListener(
                                     void *						inClientData,
                                     AudioFileStreamID			inAudioFileStream,
                                     AudioFileStreamPropertyID	inPropertyID,
                                     UInt32 *					ioFlags)
{
    Steam * steam = (Steam *)inClientData;
    assert(IS_INSTANCE_OF(steam, Steam));
    [steam handleAudioFileStream:inAudioFileStream property:inPropertyID flags:ioFlags];
}

void myAudioFileStreamPackets(
                            void *							inClientData,
                            UInt32							inNumberBytes,
                            UInt32							inNumberPackets,
                            const void *					inInputData,
                            AudioStreamPacketDescription	*inPacketDescriptions)
{
    Steam * steam = (Steam *)inClientData;
    assert(IS_INSTANCE_OF(steam, Steam));
    [steam handleAudioFileStreamPacketsNumberBytes:inNumberBytes 
                                     numberPackets:inNumberPackets 
                                         inputData:inInputData 
                                 packetDescription:inPacketDescriptions];
}

void myAudioQueueOutputCallback(
                                void *                  inUserData,
                                AudioQueueRef           inAQ,
                                AudioQueueBufferRef     inBuffer)
{
    Steam * steam = (Steam *)inUserData;
    assert(IS_INSTANCE_OF(steam, Steam));
    [steam handleAudioQueue:inAQ completedBuffer:inBuffer];
}

void myAudioQueuePropertyListenerProc(
                                      void *                  inUserData,
                                      AudioQueueRef           inAQ,
                                      AudioQueuePropertyID    inID)
{
    Steam * steam = (Steam *)inUserData;
    assert(IS_INSTANCE_OF(steam, Steam));
    [steam handleAudioQueue:inAQ property:inID];
}

@implementation Steam (Audio)
@dynamic audioState;
@dynamic audioError;
@dynamic audioQueueIsRunning;

- (void)startAudio
{
    @synchronized(self) {
        if (SteamAudioInitialized == self.audioState) {
            [_audioThreadCondition lock];
            if (NO == _audioThreadStarted) { //防御判断
                assert(nil == _audioThread);
                _audioThread = [[NSThread alloc] initWithTarget:self selector:@selector(audioWorkerThread:) object:nil];
                self.audioState = SteamAudioThreadStarted;
                [_audioThread setName:@"audioThread"];
                _audioThreadStarted = YES;
                [_audioThread start];
            }
            [_audioThreadCondition unlock];
        }
        else if (SteamPaused == self.state) {
            [_audioQueueLock lock];
            if (_audioQueueRef) {
                AudioQueueStart(_audioQueueRef, NULL);
            }
            [_audioQueueLock unlock];
        }
    }
}

- (void)resetAudio
{
    [_audioQueueLock lock];
    if (_audioQueueRef) {
        AudioQueueReset(_audioQueueRef);
    }
    [_audioQueueLock unlock];
}

- (void)stopAudio
{
    [self signalAudioFileType];
    
// 这里容易产生死锁
    //当failedWithOSStatus里调用stopAudio时，外面可能已经有了audioQueueLock
    //如果在Lock内调用了此方法，会导致死锁
    [_audioQueueLock lock];
    if (_audioQueueRef) {
        AudioQueueStop(_audioQueueRef, YES);
    }
    if (SteamAudioFailed != self.audioState) {
        self.audioState = SteamAudioStopped; //如果在
    }
    [_audioQueueLock unlock];
    [self freeAudioQueue];
}

- (void)waitForAudioStopped
{
    STEAM_LOG(STEAM_DEBUG_AUDIO, @"waiting for audio stopped");
    [self freeAudioQueue];
    
    [_audioThreadCondition lock];
    while (_audioThreadStarted) {
        [_audioThreadCondition wait];
    }
    [_audioThreadCondition unlock];
    STEAM_LOG(STEAM_DEBUG_AUDIO, @"audio stopped");
}

- (void)signalAudioFileType
{
    [_audioFileTypeCondition lock];//等待
    if (!_audioFileTypeHint) {
        _audioFileTypeHint = 1;
    }
    [_audioFileTypeCondition signal];
    [_audioFileTypeCondition unlock];
}

- (void)freeAudioQueue
{
    [_audioQueueLock lock];
    if (_audioQueueRef) {
        AudioQueueDispose(_audioQueueRef, YES);
        _audioQueueRef = NULL;
    }
    
    [_audioQueueBufferConditionLock lock]; //释放了其他地方的锁，可能导致内存泄漏
    for (int i = 0; i < _audioQueueBuffersNum; i ++) {
        AudioQueueBufferRef * refAQBuf = _audioQueueBuffers + i;
        AudioQueueFreeBuffer(_audioQueueRef, *refAQBuf);
        *refAQBuf = NULL;
    }
    [_audioQueueBufferConditionLock unlockWithCondition:AUDIOQUEUE_BUFFER_CONDITION_HASSLOT];
    [_audioQueueLock unlock];
}

- (NSTimeInterval)audioElapsedTime
{
    NSTimeInterval elapsedTime = 0;
    [_audioQueueLock lock];
    if (_audioQueueRef) {
        AudioTimeStamp timeStamp;
        OSStatus st = AudioQueueGetCurrentTime(_audioQueueRef, NULL, &timeStamp, NULL);
        if (!st) {
            @synchronized(self) {
                elapsedTime = timeStamp.mSampleTime / _audioFormat.mSampleRate;
            }
        }
    }
    [_audioQueueLock unlock];
    return elapsedTime;
}

- (NSTimeInterval)audioDuration
{
    return 0;
}

#pragma mark - state/error setter/getter
- (void)setAudioState:(SteamAudioState)audioState
{
    @synchronized(self) {
        _audioState = audioState;
        [self postNotificationName:SteamAudioStateChangedNotification];
    }
}

- (SteamAudioState)audioState
{
    @synchronized(self) {
        return _audioState;
    }
}

- (void)setAudioError:(SteamAudioError)audioError
{
    @synchronized(self) {
        _audioError = audioError;
        self.audioState = SteamAudioFailed;
    }
}

- (SteamAudioError)audioError
{
    @synchronized(self) {
        return _audioError;
    }
}

- (void)failedWithSteamAudioError:(SteamAudioError)error
{
    self.audioError = error;
    [self stop];
}

- (void)audioWorkerThread:(id)object
{
    @autoreleasepool {
        if (SteamAudioThreadStarted == self.audioState) {
            STEAM_LOG(STEAM_DEBUG_AUDIO, @"audio thread started");
            NSThread * currentThread = [NSThread currentThread];
#if NON_OBJC_ARC
            [[currentThread retain] autorelease];
#endif

            OSStatus st = 0;
            AudioFileStreamID audioFileStream;
            [_audioFileTypeCondition lock];//等待buffer请求得到正确的hint
            while (!_audioFileTypeHint) {
                [_audioFileTypeCondition wait];
            }
            if (_audioFileTypeHint && 1 != _audioFileTypeHint) {
                st = AudioFileStreamOpen((void *)self, myAudioFileStreamPropertyListener, myAudioFileStreamPackets, _audioFileTypeHint, &audioFileStream);
                if (st) {
                    [self audioFileStream:audioFileStream failedWithOSStatus:st as:@"AudioFileStreamOpen"];
                }
            }
            [_audioFileTypeCondition unlock];
            
            [_audioQueueBufferConditionLock lock];
            _audioQueueBuffers = (AudioQueueBufferRef *)malloc(sizeof(AudioQueueBufferRef) * _audioQueueBuffersNum);
            if (NULL == _audioQueueBuffers) {
                [self failedWithSteamAudioError:SteamAudioErrorInsufficientMemory];
                _audioQueueBuffersNum = 0;
            }
            else {
                memset(_audioQueueBuffers, 0, sizeof(AudioQueueBufferRef) * _audioQueueBuffersNum);
            }
            [_audioQueueBufferConditionLock unlock];
            
            UInt32 bufferSize = kDefaultPacketBytesSize;
            UInt8 * buffer = (UInt8 *)malloc(sizeof(UInt8) * kDefaultPacketBytesSize);
            if (buffer) {
                while (![self shouldExitAudioThread]) {
                    @autoreleasepool {
                        //解析出来的queue buffer大小不均匀，导致三个audio queue buffer播放的时候会出现停顿
                        //小的queuebuffer导致线程来不及准备下面的数据
                        
                        NSUInteger readSize = [self readBuffer:buffer bufferSize:bufferSize];
                        if (readSize) {
                            STEAM_LOG(STEAM_DEBUG_AUDIO, @"read size:%u", readSize);
                            st = AudioFileStreamParseBytes(audioFileStream, readSize, buffer, 0);
                            if (st) {
                                [self audioFileStream:audioFileStream failedWithOSStatus:st as:@"AudioFileStreamParseBytes"];
                            }
                        }
                        else {
                            if (![self bufferThreadIsRunning]) {
                                break;
                            }
                        }
                    }
                    [NSThread sleepForTimeInterval:0.1];
                }
            }
            else {
                [self failedWithSteamAudioError:SteamAudioErrorInsufficientMemory];
            }
            
            [_audioQueueBufferConditionLock lock];
            if (_audioQueueBuffers) {
                free(_audioQueueBuffers);
                _audioQueueBuffers = NULL;
                _audioQueueBuffersNum = 0;
            }
            [_audioQueueBufferConditionLock unlock];
            
            if (audioFileStream) {
                AudioFileStreamClose(audioFileStream);
                audioFileStream = NULL;
            }
            [_audioThreadCondition lock];
            _audioThreadStarted = NO;
            [_audioThreadCondition signal];
            RELEASE_SAFELY(_audioThread);
            [_audioThreadCondition unlock];
            STEAM_LOG(STEAM_DEBUG_AUDIO, @"audio worker thread exited");
        }//if
    }//autorelease
}

- (BOOL)shouldExitAudioThread
{
    @synchronized(self) {
        return (SteamStopping == _state
                || SteamAudioFailed == _audioState
                || SteamStopped == _audioState);
    }
}

#pragma mark - Audio File Stream callbacks
- (void)handleAudioFileStreamPacketsNumberBytes:(UInt32) inNumberBytes 
                                  numberPackets:(UInt32)inNumberPackets
                                      inputData:(const void *)inputData
                              packetDescription:(AudioStreamPacketDescription *)packetDescripton
{
    if (inNumberPackets) {
        OSStatus st = 0;
        BOOL isVBR = NO;
        @synchronized(self) {
            isVBR = ((0 == _audioFormat.mBytesPerPacket) || (0 == _audioFormat.mFramesPerPacket));
        }
        
        UInt32 copiedPackets = 0;
        while (copiedPackets < inNumberPackets) {
            [_audioQueueBufferConditionLock lockWhenCondition:AUDIOQUEUE_BUFFER_CONDITION_HASSLOT];
            if (SteamWorking == self.state) {
                UInt32 index = _audioQueueBufferUsedStartIndex + _audioQueueBufferUsedNumber;
                if (index >= _audioQueueBuffersNum) {
                    index -= _audioQueueBuffersNum;
                    assert(index < _audioQueueBufferUsedStartIndex);
                }
                AudioStreamPacketDescription * packetDesc = packetDescripton + copiedPackets;
                UInt32 singlePakcetSize = packetDesc->mDataByteSize;
                
                AudioQueueBufferRef * refAQBuf = _audioQueueBuffers + index;
                [_audioQueueLock lock];
                if (*refAQBuf) {
                    BOOL needFree = NO;
                    if ((*refAQBuf)->mAudioDataBytesCapacity < singlePakcetSize) {
                        needFree = YES;
                    }
                    else if (isVBR && packetDescripton && (*refAQBuf)->mPacketDescriptionCapacity < 1) {
                        needFree = YES;
                    }
                    if (needFree) {
                        AudioQueueFreeBuffer(_audioQueueRef, *refAQBuf);
                        *refAQBuf = NULL;
                    }
                }
                if (NULL == *refAQBuf) {
                    UInt32 allocatedBufferSize = MAX(_maxPacketBufferSize, singlePakcetSize);
                    if (isVBR) {
                        st = AudioQueueAllocateBufferWithPacketDescriptions(_audioQueueRef, allocatedBufferSize, kDefaultPacketNum, refAQBuf);
                    }
                    else {
                        st = AudioQueueAllocateBuffer(_audioQueueRef, allocatedBufferSize, refAQBuf);
                    }
                }
                
                if (!st && *refAQBuf) {
                    while(copiedPackets < inNumberPackets) {
                        AudioStreamPacketDescription * packetDesc = packetDescripton + copiedPackets;
                        UInt32 audioDataSize = (*refAQBuf)->mAudioDataByteSize;
                        if (isVBR) {
                            UInt32 packetCount = (*refAQBuf)->mPacketDescriptionCount;
                            if ((packetCount + 1 <= (*refAQBuf)->mPacketDescriptionCapacity)
                                && (audioDataSize + packetDesc->mDataByteSize <= (*refAQBuf)->mAudioDataBytesCapacity)) {
                                memcpy((*refAQBuf)->mAudioData + audioDataSize, 
                                       (UInt8*)inputData + packetDesc->mStartOffset, 
                                       packetDesc->mDataByteSize);
                                memcpy((*refAQBuf)->mPacketDescriptions + packetCount, packetDesc, sizeof(AudioStreamPacketDescription));
                                (*refAQBuf)->mPacketDescriptionCount ++;
                                (*refAQBuf)->mAudioDataByteSize += packetDesc->mDataByteSize;
                                copiedPackets ++;
                            }
                            else {
                                break;
                            }
                        
                        }
                        else if (audioDataSize + packetDesc->mDataByteSize <= (*refAQBuf)->mAudioDataBytesCapacity) {
                            memcpy((*refAQBuf)->mAudioData + audioDataSize, 
                                   (UInt8*)inputData + packetDesc->mStartOffset, 
                                   packetDesc->mDataByteSize);
                            (*refAQBuf)->mAudioDataByteSize += packetDesc->mDataByteSize;
                            copiedPackets ++;
                        }
                        else {
                            break;
                        }
                    }
                    /*//如果队列小于两个，或者buffer有数据，但不足以填充新数据，则立刻
                    //将buffer入列，否则，则尽可能充满Buffer
                    //
                    if ((copiedPackets && _audioQueueBufferUsedNumber < 2)
                        || (!copiedPackets && (*refAQBuf)->mAudioDataByteSize)) */
                    {
                        st = AudioQueueEnqueueBuffer(_audioQueueRef, *refAQBuf, isVBR?inNumberPackets:0, isVBR?packetDescripton:NULL);
                        
                        if (!st) {
#ifdef DEBUG
                            static int i = 0;
                            i ++;
                            STEAM_LOG(STEAM_DEBUG_AUDIO_EN_DEQUEUE, @"enqueued:%d (%ld bytes, %ld packets)", i, (*refAQBuf)->mAudioDataByteSize, (*refAQBuf)->mPacketDescriptionCount);
#endif
                            _audioQueueBufferUsedNumber ++;
                            if (SteamWorking == self.state) {
                                if(NO == _audioQueueIsRunning 
                                   && ((SteamBufferFinished == self.bufferState || SteamBufferFailed == self.bufferState) || _audioQueueBuffersNum == _audioQueueBufferUsedNumber)) {
                                    st = AudioQueueStart(_audioQueueRef, NULL);
                                }
                                else if(SteamAudioPaused == self.audioState){
                                    st = AudioQueueStart(_audioQueueRef, NULL);
                                }
                            }
                        }
                    }
                }
                [_audioQueueLock unlock];
            }
            NSInteger condition = (_audioQueueBufferUsedNumber < _audioQueueBuffersNum)?AUDIOQUEUE_BUFFER_CONDITION_HASSLOT:AUDIOQUEUE_BUFFER_CONDITION_FULL;
            [_audioQueueBufferConditionLock unlockWithCondition:condition];
            if (st) {
                [self audioQueue:_audioQueueRef failedWithOSStatus:st as:@"handleAudioFileStreamPackets"];
            }
        }
    }
    else {
        STEAM_LOG(STEAM_DEBUG_AUDIO, @"inNumPackets == 0");
    }
}

- (void)handleAudioFileStream:(AudioFileStreamID)audioFileStream 
                     property:(AudioFileStreamPropertyID)propertyID 
                        flags:(UInt32 *)ioFlags
{
    OSStatus st = 0;
    switch (propertyID) {
        case kAudioFileStreamProperty_ReadyToProducePackets:
            LOGSTATUS(@"ReadyToProducePackets");
        {
            OSStatus st = 0;
            OSStatus fsSt = 0;
            [_audioQueueLock lock];
            if (NULL == _audioQueueRef) {
                AudioStreamBasicDescription format;
                @synchronized(self) {
                    format = _audioFormat;
                }
                st = AudioQueueNewOutput(&format, myAudioQueueOutputCallback, (void*)self, NULL, NULL, 0, &_audioQueueRef);
                if (0 == st) {
                    st = AudioQueueAddPropertyListener(_audioQueueRef, kAudioQueueProperty_IsRunning, myAudioQueuePropertyListenerProc, (void*)self);
                    UInt32 magicCookieSize;
                    void * magicCookie = NULL;
                    
                    magicCookieSize = 0;
                    Boolean writable = false;
                    fsSt = AudioFileStreamGetPropertyInfo(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &magicCookieSize, &writable);
                    if (!fsSt) {
                        if (magicCookieSize) {
                            magicCookie = malloc(magicCookieSize);
                            if (magicCookie) {
                                fsSt = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MagicCookieData, &magicCookieSize, magicCookie);
                                if (!fsSt) {
                                    st = AudioQueueSetProperty(_audioQueueRef, kAudioQueueProperty_MagicCookie, magicCookie, magicCookieSize);
                                    free(magicCookie);
                                    magicCookie = NULL;
                                }
                            }
                            else {
                                LOGSTATUS(@"failed to alloc memory for magic cookie");
                            }
                        }
                    }
                    UInt32 packetSize = 0;
                    UInt32 size = sizeof(packetSize);
                    fsSt = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_PacketSizeUpperBound, &size, &packetSize);
                    if (fsSt || !packetSize) {
                        fsSt = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_MaximumPacketSize, &size, &packetSize);
                    }
                    [_audioQueueBufferConditionLock lock ];
                    if (packetSize) {
                        _maxPacketBufferSize = packetSize;
                    }
                    else {
                        _maxPacketBufferSize = kDefaultPacketBytesSize; //initial packetSize
                    }
                    [_audioQueueBufferConditionLock unlock];
                }
                else {
                }
            }
            [_audioQueueLock unlock];
            
            if (fsSt) {
//                [self audioFileStream:audioFileStream failedWithOSStatus:fsSt as:@"ReadyProducePackets"];
            }
            if (st) { //不可以在lock里执行
                [self audioQueue:_audioQueueRef failedWithOSStatus:st as:@"ReadyToProducePackets"];
            }
        }
            break;
        case kAudioFileStreamProperty_FileFormat:
            STEAM_LOG(STEAM_DEBUG,@"FileFormat");
/*            @synchronized(self) {
                UInt32 size = sizeof(_parsedAudioFileType);
                st = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_FileFormat, &size, &_parsedAudioFileType);
#ifdef DEBUG
                char * str = (char *)&_parsedAudioFileType;
                STEAM_LOG(STEAM_DEBUG_AUDIO, @"format:%c%c%c%c, %lu", str[3], str[2], str[1], str[0], _parsedAudioFileType);
#endif
            }
 */
            break;
        case kAudioFileStreamProperty_DataFormat:
            LOGSTATUS(@"DataFormat");
            @synchronized(self) {
                UInt32 size = sizeof(_audioFormat);
                st = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_DataFormat, &size, &_audioFormat);
                if (st) {
                    [self audioFileStream:audioFileStream failedWithOSStatus:st as:@"kAudioFileStreamProperty_DataFormat"];
                }
#ifdef DEBUG
                else {
                    char * str = (char *)&_audioFormat.mFormatID;
                    STEAM_LOG(STEAM_DEBUG_AUDIO, @"format:%c%c%c%c, %lu", str[3], str[2], str[1], str[0], _audioFormat.mFormatID);
                }
#endif
                
            }
            break;
        case kAudioFileStreamProperty_FormatList:
            LOGSTATUS(@"FormatList");
            break;
        case kAudioFileStreamProperty_MagicCookieData:
        {
        }
            break;
        case kAudioFileStreamProperty_AudioDataByteCount:
            LOGSTATUS(@"AudioDataByteCount");
            break;
        case kAudioFileStreamProperty_AudioDataPacketCount:
            LOGSTATUS(@"AudioDataPacketCount");
            break;
        case kAudioFileStreamProperty_MaximumPacketSize:
            LOGSTATUS(@"MaximumPacketSize");
            break;
        case kAudioFileStreamProperty_DataOffset:
            LOGSTATUS(@"DataOffset");
            break;
        case kAudioFileStreamProperty_ChannelLayout:
            LOGSTATUS(@"ChannelLayout");
            break;
        case kAudioFileStreamProperty_PacketToFrame:
            LOGSTATUS(@"PacketToFrame");
            break;
        case kAudioFileStreamProperty_ByteToPacket:
            LOGSTATUS(@"ByteToPacket");
            break;
        case kAudioFileStreamProperty_PacketTableInfo:
            LOGSTATUS(@"PacketTableInfo");
            break;
        case kAudioFileStreamProperty_PacketSizeUpperBound:
            LOGSTATUS(@"PacketSizeUpperBound");
            break;
        case kAudioFileStreamProperty_AverageBytesPerPacket:
            LOGSTATUS(@"AverageBytesPerPacket");
            break;
        case kAudioFileStreamProperty_BitRate:
        {
            UInt32 bitrate;
            UInt32 size = sizeof(bitrate);
            st = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_FileFormat, &size, &bitrate);
            LOGSTATUS(@"BitRate:%ld", bitrate);
        }
            break;
            
        default:
            break;
    }
}

#pragma mark - Audio Queue callbacks
- (void)handleAudioQueue:(AudioQueueRef)inAQ completedBuffer:(AudioQueueBufferRef)aqBuffer
{
    [_audioQueueBufferConditionLock lock];
    ///是否可以考虑数据重用
    assert(_audioQueueBufferUsedNumber > 0);
    _audioQueueBufferUsedStartIndex ++;
    if (_audioQueueBufferUsedStartIndex >= _audioQueueBuffersNum) {
        _audioQueueBufferUsedStartIndex = 0;
    }
#ifdef DEBUG
    static int i = 0;
    _audioQueueBufferUsedNumber --;
    i ++;
    STEAM_LOG(STEAM_DEBUG_AUDIO_EN_DEQUEUE, @"dequeued:%d (used:%ld)", i, _audioQueueBufferUsedNumber);
#endif
    
    aqBuffer->mAudioDataByteSize = 0;
    aqBuffer->mPacketDescriptionCount = 0;
    
    OSStatus st = 0;
    @synchronized(self) {
        if (0 == _audioQueueBufferUsedNumber && ![self hasBuffers]) {  //未结束下载，正在缓冲
            if(_audioQueueIsRunning) {
                if(SteamBufferBuffering == self.bufferState) {
                    st = AudioQueuePause(inAQ);
                    if (!st) {
                        self.audioState = SteamPaused;
                    }
                }
                else if(SteamBufferFinished == self.bufferState || SteamBufferFailed == self.bufferState) {
                    AudioQueueFlush(inAQ);
                    st = AudioQueueStop(inAQ, false);
                    LOGSTATUS(@"stopping");
                    if (st) {
                        [self audioQueue:inAQ failedWithOSStatus:st as:@"handleAudioFileStreamPackets:AudioQueueStop"];
                    }
                }
            }
        }
    }
    [_audioQueueBufferConditionLock unlockWithCondition:AUDIOQUEUE_BUFFER_CONDITION_HASSLOT];
    
    if (st) {
        [self audioQueue:inAQ failedWithOSStatus:st as:@"-handleAudioQueue:completedBuffer:"];
    }
}

- (void)handleAudioQueue:(AudioQueueRef)inAQ property:(AudioQueuePropertyID)property
{
    switch (property) {
        case kAudioQueueProperty_IsRunning:
        {
            UInt32 running;
            UInt32 size = sizeof(running);
            OSStatus st = AudioQueueGetProperty(inAQ, kAudioQueueProperty_IsRunning, &running, &size);
            if (!st) {
                if (running) {
                    STEAM_LOG(STEAM_DEBUG_AUDIO, @"running");
                    @synchronized(self) {
                        _audioQueueIsRunning = YES;
                        self.audioState = SteamAudioRunning;
                    }
                }
                else {
                    STEAM_LOG(STEAM_DEBUG_AUDIO, @"not running");
                    @synchronized(self) {
                        self.audioState = SteamAudioStopped;
                        _audioQueueIsRunning = NO;
                    }
                    //如果发到后台任务，则会导致self过早释放
                    [self performSelectorOnMainThread:@selector(waitForStopping) withObject:nil waitUntilDone:NO];
                }
            }
            else {
                [self audioQueue:inAQ failedWithOSStatus:st as:@"kAudioQueueProperty_IsRunning"];
            }
        }
            break;           
        default:
            LOGSTATUS(@"unhandled:%lu", property);
            break;
    }
}

#pragma mark - error status handler
- (void)audioFileStream:(AudioFileStreamID)audioFileStream failedWithOSStatus:(OSStatus)err as:(NSString *)as
{
    switch (err) {
        case kAudioFileStreamError_UnsupportedFileType:
            LOGSTATUS(@"UnsupportedFileType (%@)", as?as:@"");
            break;
        case kAudioFileStreamError_UnsupportedDataFormat:
            LOGSTATUS(@"UnsupportedDataFormat (%@)", as?as:@"");
            break;
        case kAudioFileStreamError_UnsupportedProperty:
            LOGSTATUS(@"UnsupportedProperty (%@)", as?as:@"");
            break;
        case kAudioFileStreamError_BadPropertySize:
            LOGSTATUS(@"BadPropertySize (%@)", as?as:@"");
            break;
        case kAudioFileStreamError_NotOptimized:
            LOGSTATUS(@"NotOptimized (%@)", as?as:@"");
            break;
        case kAudioFileStreamError_InvalidPacketOffset:
            LOGSTATUS(@"InvalidPacketOffset (%@)", as?as:@"");
            break;
        case kAudioFileStreamError_InvalidFile:
            LOGSTATUS(@"InvalidFile (%@)", as?as:@"");
            break;
        case kAudioFileStreamError_ValueUnknown:
            LOGSTATUS(@"ValueUnknown (%@)", as?as:@"");
            break;
        case kAudioFileStreamError_DataUnavailable:
            LOGSTATUS(@"DataUnavailable (%@)", as?as:@"");
            break;
        case kAudioFileStreamError_IllegalOperation:
            LOGSTATUS(@"IllegalOperation (%@)", as?as:@"");
            break;
        case kAudioFileStreamError_UnspecifiedError:
            LOGSTATUS(@"UnspecifiedError (%@)", as?as:@"");
            break;
        case kAudioFileStreamError_DiscontinuityCantRecover:
            LOGSTATUS(@"DiscontinuityCantRecover (%@)", as?as:@"");
            break;
        default:
        {
            char * ch = (char *)&err;
            LOGSTATUS(@"Unknown err:%ld - %c%c%c%c (%@)", err, ch[3], ch[2], ch[1], ch[0], as?as:@"");
        }
            break;
    }
    [self stop];
}

//由于stopAudio里会使用audioQueueLock，所以不可以在audioQueueLock内调用此函数
- (void)audioQueue:(AudioQueueRef)audioQueue failedWithOSStatus:(OSStatus)err as:(NSString *)as
{
    switch (err) {
        case kAudioQueueErr_InvalidBuffer:
            LOGSTATUS(@"InvalidBuffer (%@)", as?as:@"");
            break;
        case kAudioQueueErr_BufferEmpty:
            LOGSTATUS(@"BufferEmpty (%@)", as?as:@"");
            break;
        
        case kAudioQueueErr_DisposalPending:
            LOGSTATUS(@"DisposalPending (%@)", as?as:@"");
            break;
        case kAudioQueueErr_InvalidProperty:
            LOGSTATUS(@"InvalidProperty (%@)", as?as:@"");
            break;
        case kAudioQueueErr_InvalidPropertySize:
            LOGSTATUS(@"InvalidPropertySize (%@)", as?as:@"");
            break;
        case kAudioQueueErr_InvalidParameter:
            LOGSTATUS(@"InvalidParameter (%@)", as?as:@"");
            break;
        case kAudioQueueErr_CannotStart:
            LOGSTATUS(@"CannotStart (%@)", as?as:@"");
            break;
        case kAudioQueueErr_InvalidDevice:
            LOGSTATUS(@"InvalidDevice (%@)", as?as:@"");
            break;
        case kAudioQueueErr_BufferInQueue:
            LOGSTATUS(@"BufferInQueue (%@)", as?as:@"");
            break;
        case kAudioQueueErr_InvalidRunState:
            LOGSTATUS(@"InvalidRunState (%@)", as?as:@"");
            break;
        case kAudioQueueErr_InvalidQueueType:
            LOGSTATUS(@"InvalidQueueType (%@)", as?as:@"");
            break;
        case kAudioQueueErr_Permissions:
            LOGSTATUS(@"Permissions (%@)", as?as:@"");
            break;
        case kAudioQueueErr_InvalidPropertyValue:
            LOGSTATUS(@"InvalidPropertyValue (%@)", as?as:@"");
            break;
        case kAudioQueueErr_PrimeTimedOut:
            LOGSTATUS(@"PrimeTimedOut (%@)", as?as:@"");
            break;
        case kAudioQueueErr_CodecNotFound:
            LOGSTATUS(@"CodecNotFound (%@)", as?as:@"");
            break;
        case kAudioQueueErr_InvalidCodecAccess:
            LOGSTATUS(@"InvalidCodecAccess (%@)", as?as:@"");
            break;
        case kAudioQueueErr_QueueInvalidated:
            LOGSTATUS(@"QueueInvalidated (%@)", as?as:@"");
            break;
        case kAudioQueueErr_RecordUnderrun: //iOS 5.0+
            LOGSTATUS(@"RecordUnderrun (%@)", as?as:@"");
            break;
        case kAudioQueueErr_EnqueueDuringReset:
            LOGSTATUS(@"EnqueueDuringReset (%@)", as?as:@"");
            break;
        case kAudioQueueErr_InvalidOfflineMode:
            LOGSTATUS(@"InvalidOfflineMode (%@)", as?as:@"");
            break;
        case kAudioFormatUnsupportedDataFormatError:
            LOGSTATUS(@"kAudioFormatUnsupportedDataFormatError (%@)", as?as:@"");
            break;
        case kAudioFormatUnsupportedPropertyError:
            LOGSTATUS(@"kAudioFormatUnsupportedPropertyError (%@)", as?as:@"");
            break;
        default:
        {
            char * e = (char *)&err;
            LOGSTATUS(@"unknown err:%ld - %c%c%c%c (%@)", err, e[3], e[2], e[1], e[0], as?as:@"");
        }
    }
    [self stop];
}


@end
