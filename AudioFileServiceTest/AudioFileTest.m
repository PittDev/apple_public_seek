//
//  AudioFileTest.m
//  AudioFileServiceTest
//
//  Created by Pitt on 12/08/2022.
//

#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import "AudioFileTest.h"

#pragma mark - Constants / Main Struct / Utils
#define kBufferDurationInSeconds 0.5
#define kNumberOfPlaybackBuffers 1

BOOL fakeSeekDone = NO;
typedef struct PlaybackCallbackData {
  AudioFileID                   playbackFile;
  SInt64                        packetPosition;
  UInt32                        numOfBytesToRead;
  UInt32                        numOfPacketsToRead;
  AudioStreamPacketDescription* packetDescs;
  Boolean                       isDone;
  FILE*                         rawFile;
} PlaybackCallbackData;

void CheckError(OSStatus error, const char *operation) {
  if (error != noErr) {
    NSLog(@"An error occurred while doing this operation: %s.\nOSStatus: %d", operation, error);
    exit(1);
  }
}

#pragma mark - Audio File Callback
OSStatus readProc(void *inClientData,
                  SInt64 inPosition,
                  UInt32 requestCount,
                  void *buffer,
                  UInt32 *actualCount) {
  
  // Read bytes from rawFile
  PlaybackCallbackData *playbackCallbackData = (PlaybackCallbackData *)inClientData;
  if (playbackCallbackData->rawFile == NULL) {
    return -1;
  }
  fseek(playbackCallbackData->rawFile, inPosition, SEEK_SET);
  *actualCount = (UInt32)fread(buffer, 1, requestCount, playbackCallbackData->rawFile);
  printf("Bytes to read: [%lld - %lld] - Count: %u\n", inPosition, inPosition + requestCount - 1, requestCount);
  return noErr;
}

SInt64 getSizeProc(void *inClientData) {
  
  // Get file size
  PlaybackCallbackData *playbackCallbackData = (PlaybackCallbackData *)inClientData;
  if (playbackCallbackData->rawFile == NULL) {
    return -1;
  }
  SInt64 currentPosition = ftell(playbackCallbackData->rawFile);
  fseek(playbackCallbackData->rawFile, 0, SEEK_END);
  SInt64 fileSize = ftell(playbackCallbackData->rawFile);
  fseek(playbackCallbackData->rawFile, currentPosition, SEEK_SET);
  return fileSize;
}

#pragma mark - Audio Queue Callbacks
static void MyAQOutputCallback(void *inUserData,
                               AudioQueueRef inAQ,
                               AudioQueueBufferRef inCompleteAQBuffer) {
  PlaybackCallbackData *playbackCallbackData = (PlaybackCallbackData *)inUserData;
  if (playbackCallbackData->isDone) {
    return;
  }
  printf("----- Packets to read: [%lld - %lld]\n",
         playbackCallbackData->packetPosition,
         playbackCallbackData->packetPosition + playbackCallbackData->numOfPacketsToRead - 1);
  
  UInt32 numOfBytes = playbackCallbackData->numOfBytesToRead;
  UInt32 numOfPackets = playbackCallbackData->numOfPacketsToRead;
  CheckError(AudioFileReadPacketData(playbackCallbackData->playbackFile,
                                     false,
                                     &numOfBytes,
                                     playbackCallbackData->packetDescs,
                                     playbackCallbackData->packetPosition,
                                     &numOfPackets,
                                     inCompleteAQBuffer->mAudioData), "Reading packet data from audio file");
  if (numOfPackets > 0 && numOfBytes > 0) {
    inCompleteAQBuffer->mAudioDataByteSize = numOfBytes;
    CheckError(AudioQueueEnqueueBuffer(inAQ,
                                       inCompleteAQBuffer,
                                       (playbackCallbackData->packetDescs ? numOfPackets : 0),
                                       playbackCallbackData->packetDescs), "Audio enqueuing buffer");
    playbackCallbackData->packetPosition += numOfPackets;
  }
  else {
    CheckError(AudioQueueStop(inAQ, false), "Asynchronously stopping the queue");
    playbackCallbackData->isDone = true;
  }
  
  // APPLE: Simulate a seek here
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    if (playbackCallbackData->packetPosition >= 40 && !fakeSeekDone) {
      fakeSeekDone = true;
      playbackCallbackData->packetPosition = 6000;
      printf("------------------------- Fake seek has been done here -------------------------\n");
    }
  });
}

#pragma mark - Buffer and Packet Management
void CalculateBytesForTime(AudioFileID audioFile,
                           const AudioStreamBasicDescription* inAudioStreamBasicDescription,
                           Float64 bufferDurationInSeconds,
                           UInt32* oBufferByteSize,
                           UInt32* oNumPacketsToRead) {
  UInt32 packetSizeUpperBound = 0;
  UInt32 packetSizeUpperBoundSize = sizeof(packetSizeUpperBound);
  
  // kAudioFilePropertyPacketSizeUpperBound
  // a UInt32 for the theoretical maximum packet size in the file (without actually scanning
  // the whole file to find the largest packet, as may happen with kAudioFilePropertyMaximumPacketSize).
  CheckError(AudioFileGetProperty(audioFile,
                                  kAudioFilePropertyPacketSizeUpperBound,
                                  &packetSizeUpperBoundSize,
                                  &packetSizeUpperBound), "Getting the packet size uppper bound from the audio file");
  const int maxBufferSize = 0x100000; // 128KB
  const int minBufferSize = 0x4000;  // 16KB
  UInt32 totalNumberOfPackets = 0;
  
  if (inAudioStreamBasicDescription->mFramesPerPacket) {
    Float64 totalNumberOfSamples = inAudioStreamBasicDescription->mSampleRate * bufferDurationInSeconds;
    UInt32 totalNumberOfFrames = ceil(totalNumberOfSamples); // 1 Frame for each 1 Sample, but round up
    totalNumberOfPackets = totalNumberOfFrames / inAudioStreamBasicDescription->mFramesPerPacket;
  }
  else {
    // If frames (samples) per packet is zero, then the codec has no predictable packet size for given time.
    // In that case, we will assume the maximum of 1 packet to size the buffer for given duration
    totalNumberOfPackets = 1;
  }
  
  if (inAudioStreamBasicDescription->mBytesPerPacket) {
    *oBufferByteSize = inAudioStreamBasicDescription->mBytesPerPacket * totalNumberOfPackets;
  }
  else {
    *oBufferByteSize = packetSizeUpperBound * totalNumberOfPackets;
  }
  
  if (*oBufferByteSize > maxBufferSize) {
    // Let's not cross the limit if +maxBufferSize+
    *oBufferByteSize = maxBufferSize;
  }
  else if (*oBufferByteSize < minBufferSize) {
    // but also, let's make sure we are not very small
    *oBufferByteSize = minBufferSize;
  }
  
  // Since, we might truncate the upper size (if it is greater than the maxBufferSize),
  // we make sure that the number of packets is good for the buffer size calculated.
  *oNumPacketsToRead = *oBufferByteSize / packetSizeUpperBound;
}

static void AllocateMemoryForPacketDescriptionsArray(const AudioStreamBasicDescription *inAudioStreamBasicDescription,
                                                     PlaybackCallbackData *ioPlaybackCallbackData) {
  Boolean isVBRorCBRwithUnequalChannelSizes = inAudioStreamBasicDescription->mBytesPerPacket == 0 ||
                                              inAudioStreamBasicDescription->mFramesPerPacket == 0;
  if (isVBRorCBRwithUnequalChannelSizes) {
    UInt32 bytesToAllocate = sizeof(AudioStreamBasicDescription) * ioPlaybackCallbackData->numOfPacketsToRead;
    ioPlaybackCallbackData->packetDescs = (AudioStreamPacketDescription*) malloc(bytesToAllocate);
  }
  else {
    ioPlaybackCallbackData->packetDescs = NULL;
  }
}

#pragma mark - Main Function
void launchTest(void) {
  @autoreleasepool {
    
    // Open the Audio File
    NSLog(@"Starting ...\n");
    NSURL *filePath = [[NSBundle mainBundle] URLForResource:@"LongTrack2" withExtension:@"flac"];
    const char* fileURL = [filePath.path cStringUsingEncoding:NSUTF8StringEncoding];
    PlaybackCallbackData playbackCallbackData = {0};
    playbackCallbackData.rawFile = fopen(fileURL, "r");
    CheckError(AudioFileOpenWithCallbacks(&playbackCallbackData,
                                          readProc,
                                          NULL,
                                          getSizeProc,
                                          NULL,
                                          0,
                                          &playbackCallbackData.playbackFile),
               "Opening the audio file");
        
    // Get its Audio Description
    AudioStreamBasicDescription audioStreamBasicDescription;
    UInt32 audioStreamBasicDescriptionSize = sizeof(AudioStreamBasicDescription);
    CheckError(AudioFileGetProperty(playbackCallbackData.playbackFile,
                                    kAudioFilePropertyDataFormat,
                                    &audioStreamBasicDescriptionSize,
                                    &audioStreamBasicDescription), "Getting the audio stream basic description need from the audio file");
    NSLog(@"Audio Stream Basic Description\n");
    NSLog(@"Sample Rate: %f\n", audioStreamBasicDescription.mSampleRate);
    UInt32 formatID4cc = CFSwapInt32HostToBig(audioStreamBasicDescription.mFormatID);
    NSLog(@"Format ID: %4.4s\n", (char *)&formatID4cc);
    NSLog(@"Bytes per packet: %d\n", audioStreamBasicDescription.mBytesPerPacket);
    NSLog(@"Frames per packet: %d\n", audioStreamBasicDescription.mFramesPerPacket);
    NSLog(@"Bytes per frame: %d\n", audioStreamBasicDescription.mBytesPerFrame);
    NSLog(@"Channels per frame: %d\n", audioStreamBasicDescription.mChannelsPerFrame);
    NSLog(@"Bits per channel: %d\n", audioStreamBasicDescription.mBitsPerChannel);
    
    // Get markers property to see if it can be read by CoreAudio
    UInt32 propSize;
    UInt32 writable;
    OSStatus markerErr = AudioFileGetPropertyInfo(playbackCallbackData.playbackFile,
                                                  kAudioFilePropertyMarkerList,
                                                  &propSize,
                                                  &writable);
    NSLog(@"Get 'kAudioFilePropertyMarkerList' property error: %d", markerErr);
    
    // Create an AudioQueue
    AudioQueueRef queue;
    CheckError(AudioQueueNewOutput(&audioStreamBasicDescription,
                                   MyAQOutputCallback,
                                   &playbackCallbackData,
                                   NULL, NULL, 0,
                                   &queue), "Initializing the audio queue");
    CalculateBytesForTime(playbackCallbackData.playbackFile,
                          &audioStreamBasicDescription,
                          kBufferDurationInSeconds,
                          &playbackCallbackData.numOfBytesToRead,
                          &playbackCallbackData.numOfPacketsToRead);
    NSLog(@"Number of bytes for buffer: %d\n", playbackCallbackData.numOfBytesToRead);
    NSLog(@"Number of packets for buffer: %d\n", playbackCallbackData.numOfPacketsToRead);
    AllocateMemoryForPacketDescriptionsArray(&audioStreamBasicDescription, &playbackCallbackData);
    
    // Allocate audio queue buffers and fill them in with initial data using the callback function
    AudioQueueBufferRef buffers[kNumberOfPlaybackBuffers];
    playbackCallbackData.isDone = FALSE;
    playbackCallbackData.packetPosition = 0;
    for (int i = 0; i < kNumberOfPlaybackBuffers; i++) {
      CheckError(AudioQueueAllocateBuffer(queue,
                                          playbackCallbackData.numOfBytesToRead,
                                          &buffers[i]), "Allocating audio queue buffer");
      
      MyAQOutputCallback(&playbackCallbackData, queue, buffers[i]); // Note: The actual enqueueing of the buffer is done by the callback itself.
      if (playbackCallbackData.isDone) { // just in case the audio is less than 1.5 seconds (kNumberOfPlaybackBuffers * kBufferDurationInSeconds)
        break;
      }
    }
    
    // Start the Audio Queue
    CheckError(AudioQueueStart(queue, NULL), "Audio queue start....the playback");
    getchar();
    
    // Clean up
    playbackCallbackData.isDone = TRUE;
    CheckError(AudioQueueStop(queue, TRUE), "Stopping Audio Queue...");
    CheckError(AudioQueueDispose(queue, TRUE), "Disposing Audio Queue...");
    if (playbackCallbackData.packetDescs) {
      free(playbackCallbackData.packetDescs);
    }
    CheckError(AudioFileClose(playbackCallbackData.playbackFile), "Closing audio file...");
    fclose(playbackCallbackData.rawFile);
    NSLog(@"End of the test\n");
  }
}
