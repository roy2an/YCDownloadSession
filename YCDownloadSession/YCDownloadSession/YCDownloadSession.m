//
//  YCDownloadSession.m
//  YCDownloadSession
//
//  Created by wz on 17/3/14.
//  Copyright © 2017年 onezen.cc. All rights reserved.
//

#import "YCDownloadSession.h"
#import "NSURLSession+CorrectedResumeData.h"

#define IS_IOS10ORLATER ([[[UIDevice currentDevice] systemVersion] floatValue] >= 10)
static NSString * const kIsAllowCellar = @"kIsAllowCellar";
@interface YCDownloadSession ()<NSURLSessionDownloadDelegate>

@property (nonatomic, strong) NSMutableDictionary *downloadTasks;//正在下载的task
@property (nonatomic, strong) NSMutableDictionary *downloadedTasks;//下载完成的task
@property (nonatomic, strong, readonly) NSURLSession *downloadSession;
@property (nonatomic, assign) BOOL isNeedCreateSession;

@end

@implementation YCDownloadSession

static YCDownloadSession *_instance;

+ (instancetype)downloadSession {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[self alloc] init];
    });
    return _instance;
}


- (instancetype)init {
    if (self = [super init]) {
        //初始化
        _downloadSession = [self getDownloadURLSession];
        _maxTaskCount = 1;
        self.downloadTasks = [NSKeyedUnarchiver unarchiveObjectWithFile:[self getArchiverPathIsDownloaded:false]];
        self.downloadedTasks = [NSKeyedUnarchiver unarchiveObjectWithFile:[self getArchiverPathIsDownloaded:true]];
        
        //获取保存在本地的数据是否为空，为空则初始化
        if(!self.downloadedTasks) self.downloadedTasks = [NSMutableDictionary dictionary];
        if(!self.downloadTasks) self.downloadTasks = [NSMutableDictionary dictionary];
        
        //获取背景session正在运行的(app重启，或者闪退会有任务)
        NSMutableDictionary *dictM = [self.downloadSession valueForKey:@"tasks"];
        [dictM enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
            YCDownloadTask *task = [self getDownloadTaskWithUrl:[YCDownloadTask getURLFromTask:obj] isDownloadList:true];
            if(!task){
                [obj cancel];
            }else{
                task.downloadTask = obj;
            }
        }];
        //获取后台下载缓存在本地的数据
        [self.downloadedTasks enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, YCDownloadTask *obj, BOOL * _Nonnull stop) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:obj.tempPath]) {
                [[NSFileManager defaultManager] moveItemAtPath:obj.tempPath toPath:[YCDownloadTask savePathWithSaveName:obj.saveName] error:nil];
            }
        }];
        
        //app重启，或者闪退的任务全部暂停
        [self pauseAllDownloadTask];
        
        
    }
    return self;
}

- (NSURLSession *)getDownloadURLSession {
    
    NSURLSession *session = nil;
    NSString *bundleId = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleIdentifier"];
    NSString *identifier = [NSString stringWithFormat:@"%@.BackgroundSession", bundleId];
    NSURLSessionConfiguration* sessionConfig = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:identifier];
    sessionConfig.allowsCellularAccess = [[NSUserDefaults standardUserDefaults] boolForKey:kIsAllowCellar];
    session = [NSURLSession sessionWithConfiguration:sessionConfig
                                            delegate:self
                                       delegateQueue:[NSOperationQueue mainQueue]];
    return session;
}


- (void)recreateSession {
    
    _downloadSession = [self getDownloadURLSession];
    NSLog(@"recreate Session success");
    //恢复正在下载的task状态
    [self.downloadTasks enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        YCDownloadTask *task = obj;
        task.downloadTask = nil;
        if (task.needToRestart) {
            task.needToRestart = false;
            [self resumeDownloadTask:task];
        }
    }];
}


-(void)setMaxTaskCount:(NSInteger)maxTaskCount {
    if (maxTaskCount>3) {
        _maxTaskCount = 3;
    }else if(maxTaskCount <= 0){
        _maxTaskCount = 1;
    }else{
        _maxTaskCount = maxTaskCount;
    }
}

- (NSInteger)currentTaskCount {
    NSMutableDictionary *dictM = [self.downloadSession valueForKey:@"tasks"];
    return dictM.count;
}

#pragma mark - public


- (void)startDownloadWithUrl:(NSString *)downloadURLString delegate:(id<YCDownloadTaskDelegate>)delegate{
    if (downloadURLString.length == 0)  return;
    
    //判断是否是下载完成的任务
    YCDownloadTask *task = [self getDownloadTaskWithUrl:downloadURLString isDownloadList:false];
    if (task) {
        task.delegate = delegate;
        [self downloadStatusChanged:YCDownloadStatusFinished task:task];
        return;
    }
    //读取正在下载的任务
    task = [self getDownloadTaskWithUrl:downloadURLString isDownloadList:true];
    
    if (!task) {
        //判断任务的个数，如果达到最大值则返回，回调等待
        if([self currentTaskCount] >= self.maxTaskCount){
            [self createDownloadTaskItemWithUrl:downloadURLString delegate:delegate];
            [self downloadStatusChanged:YCDownloadStatusWaiting task:task];
        }else {
            [self createDownloadTaskWithUrl:downloadURLString delegate:delegate];
        }
    }else{
        task.delegate = delegate;
        if ([self detectDownloadTaskIsFinished:task]) {
            [self downloadStatusChanged:YCDownloadStatusFinished task:task];
            return;
        }
        
        if (task.downloadTask && task.downloadTask.state == NSURLSessionTaskStateRunning && task.resumeData.length == 0) {
            [task.downloadTask resume];
            [self downloadStatusChanged:YCDownloadStatusDownloading task:task];
            return;
        }
        //        if(task.downloadedSize == 0) {
        //            [task.downloadTask cancel];
        //            task.downloadTask = nil;
        //        }
        [self resumeDownloadTask:task];
    }
}

- (void)pauseDownloadWithUrl:(NSString *)downloadURLString {
    [self pauseDownloadTask:[self getDownloadTaskWithUrl:downloadURLString isDownloadList:true] toNextTask:true];
}

- (void)pauseAllDownloadTask{
    [self.downloadTasks enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        [self pauseDownloadTask:obj toNextTask:false];
    }];
}

- (void)resumeDownloadWithUrl:(NSString *)downloadURLString delegate:(id<YCDownloadTaskDelegate>)delegate{
    //判断是否是下载完成的任务
    YCDownloadTask *task = [self getDownloadTaskWithUrl:downloadURLString isDownloadList:false];
    if (task) {
        task.delegate = delegate;
        [self downloadStatusChanged:YCDownloadStatusFinished task:task];
        return;
    }
    task = [self getDownloadTaskWithUrl:downloadURLString isDownloadList:true];
    if(delegate) task.delegate = delegate;
    [self resumeDownloadTask: task];
}

- (void)stopDownloadWithUrl:(NSString *)downloadURLString {
    @try {
        [self stopDownloadWithTask:[self getDownloadTaskWithUrl:downloadURLString isDownloadList:true]];
        [self.downloadTasks removeObjectForKey:downloadURLString];
        [self.downloadedTasks removeObjectForKey:downloadURLString];
    } @catch (NSException *exception) {  }
    [self saveDownloadStatus];
}

- (void)allowsCellularAccess:(BOOL)isAllow {
    
    [[NSUserDefaults standardUserDefaults] setBool:isAllow forKey:kIsAllowCellar];
    [self.downloadTasks enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        YCDownloadTask *task = obj;
        if (task.downloadTask.state == NSURLSessionTaskStateRunning) {
            task.needToRestart = true;
            [self pauseDownloadTask:task toNextTask:false];
        }
    }];

    [_downloadSession invalidateAndCancel];
    self.isNeedCreateSession = true;
}

- (BOOL)isAllowsCellularAccess {
    
    return [[NSUserDefaults standardUserDefaults] boolForKey:kIsAllowCellar];
}

#pragma mark - private

- (void)createDownloadTaskWithUrl:(NSString *)downloadURLString delegate:(id<YCDownloadTaskDelegate>)delegate{
    
    NSURL *downloadURL = [NSURL URLWithString:downloadURLString];
    NSURLRequest *request = [NSURLRequest requestWithURL:downloadURL];
    NSURLSessionDownloadTask *downloadTask = [self.downloadSession downloadTaskWithRequest:request];
    YCDownloadTask *task = [self createDownloadTaskItemWithUrl:downloadURLString delegate:delegate];
    task.downloadTask = downloadTask;
    [downloadTask resume];
    [self downloadStatusChanged:YCDownloadStatusDownloading task:task];
}

- (YCDownloadTask *)createDownloadTaskItemWithUrl:(NSString *)downloadURLString delegate:(id<YCDownloadTaskDelegate>)delegate{
    
    YCDownloadTask *task = [[YCDownloadTask alloc] init];
    task.downloadURL = downloadURLString;
    task.delegate = delegate;
    [self.downloadTasks setObject:task forKey:task.downloadURL];
    [self downloadStatusChanged:YCDownloadStatusWaiting task:task];
    return task;
}

- (void)pauseDownloadTask:(YCDownloadTask *)task toNextTask:(BOOL)toNext{
    [task.downloadTask cancelByProducingResumeData:^(NSData * resumeData) {
        if(resumeData.length>0) task.resumeData = resumeData;
        task.downloadTask = nil;
        [self saveDownloadStatus];
        [self downloadStatusChanged:YCDownloadStatusPaused task:task];
        if (toNext) {
            [self startNextDownloadTask];
        }
    }];
}


- (void)resumeDownloadTask:(YCDownloadTask *)task {
    
    if(!task) return;
    if (([self currentTaskCount] >= self.maxTaskCount) && task.downloadStatus != YCDownloadStatusDownloading) {
        [self downloadStatusChanged:YCDownloadStatusWaiting task:task];
        return;
    }
    if ([self detectDownloadTaskIsFinished:task]) {
        [self downloadStatusChanged:YCDownloadStatusFinished task:task];
        return;
    }
    
    NSData *data = task.resumeData;
    if (data.length > 0) {
        if(task.downloadTask && task.downloadTask.state == NSURLSessionTaskStateRunning){
            [self downloadStatusChanged:YCDownloadStatusDownloading task:task];
            return;
        }
        NSURLSessionDownloadTask *downloadTask = nil;
        if (IS_IOS10ORLATER) {
            @try { //非ios10 升级到ios10会引起崩溃
                downloadTask = [self.downloadSession downloadTaskWithCorrectResumeData:data];
            } @catch (NSException *exception) {
                downloadTask = [self.downloadSession downloadTaskWithResumeData:data];
            }
        } else {
            downloadTask = [self.downloadSession downloadTaskWithResumeData:data];
        }
        task.downloadTask = downloadTask;
        [downloadTask resume];
        task.resumeData = nil;
        [self downloadStatusChanged:YCDownloadStatusDownloading task:task];
        
    }else{
        //没有下载任务，那么重新创建下载任务；  部分下载暂停异常 NSURLSessionTaskStateCompleted ，但并没有完成，所以重新下载
        if (!task.downloadTask || task.downloadTask.state == NSURLSessionTaskStateCompleted) {
            NSString *url = task.downloadURL;
            if (url.length ==0) return;
            [self.downloadTasks removeObjectForKey:url];
            [self createDownloadTaskWithUrl:url delegate:task.delegate];
        }else{
            [task.downloadTask resume];
            [self downloadStatusChanged:YCDownloadStatusDownloading task:task];
        }
    }
}


- (void)stopDownloadWithTask:(YCDownloadTask *)task {
    [task.downloadTask cancel];
}



- (void)startNextDownloadTask {
    //某一任务下载完成后，或者暂停之后，session的tasks里还是有原先任务，所以保证1秒的延时
    //延时有不确定性，找到更好的替换方案，可以替换
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self currentTaskCount] < self.maxTaskCount) {
            [self.downloadTasks enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
                YCDownloadTask *task = obj;
                if ((!task.downloadTask || task.downloadTask.state != NSURLSessionTaskStateRunning) && task.downloadStatus == YCDownloadStatusWaiting) {
                    [self resumeDownloadTask:task];
                }
            }];
        }
    });
}


- (void)downloadStatusChanged:(YCDownloadStatus)status task:(YCDownloadTask *)task{
    
    task.downloadStatus = status;
    [self saveDownloadStatus];
    switch (status) {
        case YCDownloadStatusWaiting:
            break;
        case YCDownloadStatusDownloading:
            break;
        case YCDownloadStatusPaused:
            break;
        case YCDownloadStatusFailed:
            break;
        case YCDownloadStatusFinished:
            [self startNextDownloadTask];
            break;
        default:
            break;
    }
    
    if ([task.delegate respondsToSelector:@selector(downloadStatusChanged:downloadTask:)]) {
        [task.delegate downloadStatusChanged:status downloadTask:task];
    }
}

#pragma mark - event

- (void)saveDownloadStatus {
    
    [NSKeyedArchiver archiveRootObject:self.downloadTasks toFile:[self getArchiverPathIsDownloaded:false]];
    [NSKeyedArchiver archiveRootObject:self.downloadedTasks toFile:[self getArchiverPathIsDownloaded:true]];
}

- (NSString *)getArchiverPathIsDownloaded:(BOOL)isDownloaded {
    NSString *saveDir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, true).firstObject;
    saveDir = [saveDir stringByAppendingPathComponent:@"YCDownload"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:saveDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:saveDir withIntermediateDirectories:true attributes:nil error:nil];
    }
    saveDir = isDownloaded ? [saveDir stringByAppendingPathComponent:@"YCDownloaded.data"] : [saveDir stringByAppendingPathComponent:@"YCDownloading.data"];
    
    return saveDir;
}

- (BOOL)detectDownloadTaskIsFinished:(YCDownloadTask *)task {
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:task.tempPath]) {
        NSDictionary *dic = [[NSFileManager defaultManager] attributesOfItemAtPath:task.tempPath error:nil];
        NSInteger fileSize = dic ? (NSInteger)[dic fileSize] : 0;
        if (fileSize>0 && fileSize == task.fileSize) {
            [[NSFileManager defaultManager] moveItemAtPath:task.tempPath toPath:[YCDownloadTask savePathWithSaveName:task.saveName] error:nil];
            return true;
        }
    }else if (task.fileSize>0 && task.fileSize==task.downloadedSize){
        
        if(!task.resumeData) {
            task.downloadedSize = 0;
            task.downloadTask = nil;
        }
    }
    
    return false;
}

// 部分下载会把域名地址解析成IP地址，所以根据URL获取不到下载任务,所以根据下载文件名称获取(后台下载，重新启动，获取的的url是IP)
- (YCDownloadTask *)getDownloadTaskWithUrl:(NSString *)downloadUrl isDownloadList:(BOOL)isDownloadList{
    
    NSMutableDictionary *tasks = isDownloadList ? self.downloadTasks : self.downloadedTasks;
    NSString *fileName = downloadUrl.lastPathComponent;
    __block YCDownloadTask *task = nil;
    [tasks enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        YCDownloadTask *dTask = obj;
        if ([dTask.downloadURL.lastPathComponent isEqualToString:fileName]) {
            task = dTask;
            *stop = true;
        }
    }];
    return task;
}


#pragma mark -  NSURLSessionDelegate

//将一个后台session作废完成后的回调，用来切换是否允许使用蜂窝煤网络，重新创建session
- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(nullable NSError *)error {
    
    if (self.isNeedCreateSession) {
        self.isNeedCreateSession = false;
        [self recreateSession];
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    
    NSString *locationString = [location path];
    NSError *error;
    
    NSString *downloadUrl = [YCDownloadTask getURLFromTask:downloadTask];
    YCDownloadTask *task = [self getDownloadTaskWithUrl:downloadUrl isDownloadList:true];
    if(!task){
        NSLog(@"download finished , item nil error!!!! url: %@", downloadUrl);
        //TODO: 校验下载url
        return;
    }
    task.tempPath = locationString;
    NSDictionary *dic = [[NSFileManager defaultManager] attributesOfItemAtPath:locationString error:nil];
    NSInteger fileSize = dic ? (NSInteger)[dic fileSize] : 0;
    
    //校验文件大小
    BOOL isCompltedFile = (fileSize>0) && (fileSize == task.fileSize);
    if (!isCompltedFile) {
        //文件大小不对，从头开始下载
        [self downloadStatusChanged:YCDownloadStatusFinished task:task];
        return;
    }
    
    [[NSFileManager defaultManager] moveItemAtPath:locationString toPath:[YCDownloadTask savePathWithSaveName:task.saveName] error:&error];

    if (task.downloadURL.length != 0) {
        [self.downloadedTasks setObject:task forKey:task.downloadURL];
        [self.downloadTasks removeObjectForKey:task.downloadURL];
    }
    [self downloadStatusChanged:YCDownloadStatusFinished task:task];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes {
    
    NSLog(@"fileOffset:%lld expectedTotalBytes:%lld",fileOffset,expectedTotalBytes);
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    
    YCDownloadTask *task = [self getDownloadTaskWithUrl:[YCDownloadTask getURLFromTask:downloadTask] isDownloadList:true];
    task.downloadedSize = (NSInteger)totalBytesWritten;
    if (task.fileSize == 0)  {
        [task updateTask];
        if ([task.delegate respondsToSelector:@selector(downloadCreated:)]) {
            [task.delegate downloadCreated:task];
        }
    }
    if ([task.delegate respondsToSelector:@selector(downloadProgress:totalBytesWritten:totalBytesExpectedToWrite:)]){
        [task.delegate downloadProgress:task totalBytesWritten:totalBytesWritten totalBytesExpectedToWrite:totalBytesExpectedToWrite];
    }
    
    NSString *url = downloadTask.response.URL.absoluteString;
    NSLog(@"downloadURL: %@  downloadedSize: %zd totalSize: %zd  progress: %f", url, bytesWritten, totalBytesWritten, (float)totalBytesWritten / totalBytesExpectedToWrite);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    
    //TODO: 301/302文件记录和处理, 想办法模拟测试301定向视频
    NSLog(@"willPerformHTTPRedirection ------> %@",response);
    
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    NSLog(@"Background URL session %@ finished events.\n", session);
}


/*
 * 该方法下载成功和失败都会回调，只是失败的是error是有值的，
 * 在下载失败时，error的userinfo属性可以通过NSURLSessionDownloadTaskResumeData
 * 这个key来取到resumeData(和上面的resumeData是一样的)，再通过resumeData恢复下载
 */
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    
    if (error) {
        
        // check if resume data are available
        NSData *resumeData = [error.userInfo objectForKey:NSURLSessionDownloadTaskResumeData];
        YCDownloadTask *yctask = [self getDownloadTaskWithUrl:[YCDownloadTask getURLFromTask:task] isDownloadList:true];
        NSLog(@"pause ----->   %@     --->%zd", yctask.downloadURL, resumeData.length);
        if (resumeData) {
            //通过之前保存的resumeData，获取断点的NSURLSessionTask，调用resume恢复下载
            yctask.resumeData = resumeData;
            //id obj = [NSPropertyListSerialization propertyListWithData:resumeData options:0 format:0 error:nil];
            //NSString *str = [[NSString alloc] initWithData:resumeData encoding:NSUTF8StringEncoding];
            
        }else{
            [self downloadStatusChanged:YCDownloadStatusFailed task:yctask];
        }
    }
}



@end
