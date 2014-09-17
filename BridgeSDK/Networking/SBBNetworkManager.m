//
//  SBBNetworkManager.m
//  SBBAppleCore
//
//  Created by Dhanush Balachandran on 8/15/14.
//  Copyright (c) 2014 Y Media Labs. All rights reserved.
//

#import "SBBNetworkManager.h"
#import "SBBNetworkErrors.h"
#import "NSError+SBBAdditions.h"
#import "Reachability.h"

const NSInteger kMaxRetryCount = 5;

static SBBNetworkManager * sharedInstance;
NSString * kBackgroundSessionIdentifier = @"com.ymedialabs.backgroundsession";

/*********************************************************************************/
#pragma mark - APC Retry Object - Keeps track of retry count
/*********************************************************************************/
@interface APCNetworkRetryObject : NSObject

@property (nonatomic) NSInteger retryCount;
@property (nonatomic, copy) SBBNetworkManagerCompletionBlock completionBlock;
@property (nonatomic, copy) void (^retryBlock)(void);

@end

@implementation APCNetworkRetryObject

@end

/*********************************************************************************/
#pragma mark - APC Network Manager
/*********************************************************************************/

@interface SBBNetworkManager ()

@property (nonatomic, strong) Reachability * internetReachability;
@property (nonatomic, strong) Reachability * serverReachability;
@property (nonatomic, strong) NSString * baseURL;
@property (nonatomic, strong) NSURLSession * mainSession; //For data tasks
@property (nonatomic, strong) NSURLSession * backgroundSession; //For upload/download tasks

@end

@implementation SBBNetworkManager

/*********************************************************************************/
#pragma mark - Initializers & Accessors
/*********************************************************************************/

- (instancetype) initWithBaseURL: (NSString*) baseURL
{
    self = [super init]; //Using [self class] instead of APCNetworkManager to enable subclassing
    if (self) {
        self.baseURL = baseURL;
        self.internetReachability = [Reachability reachabilityForInternetConnection];
        NSURL * url = [NSURL URLWithString:baseURL];
        self.serverReachability = [Reachability reachabilityWithHostName:[url host]]; //Check if only hostname is required
        [self.serverReachability startNotifier]; //Turning on ONLY server reachability notifiers
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityChanged:) name:kReachabilityChangedNotification object:nil];
        
    }
    return self;
}

- (NSURLSession *)mainSession
{
    if (!_mainSession) {
        _mainSession = [NSURLSession sharedSession];
    }
    return _mainSession;
}

- (NSURLSession *)backgroundSession
{
    if (!_backgroundSession) {
        NSURLSessionConfiguration * config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:kBackgroundSessionIdentifier];
        _backgroundSession = [NSURLSession sessionWithConfiguration:config];
    }
    return _backgroundSession;
}

- (BOOL)isInternetConnected
{
    return (self.internetReachability.currentReachabilityStatus != NotReachable);
}

- (BOOL)isServerReachable
{
    return (self.serverReachability.currentReachabilityStatus != NotReachable);
}

/*********************************************************************************/
#pragma mark - basic HTTP methods
/*********************************************************************************/
-(NSURLSessionDataTask *)get:(NSString *)URLString parameters:(id)parameters completion:(SBBNetworkManagerCompletionBlock)completion
{
    return [self doDataTask:@"GET" retryObject:nil URLString:URLString parameters:parameters completion:completion];
}

- (NSURLSessionDataTask *)post:(NSString *)URLString parameters:(id)parameters completion:(SBBNetworkManagerCompletionBlock)completion
{
    return [self doDataTask:@"POST" retryObject:nil URLString:URLString parameters:parameters completion:completion];
}


/*********************************************************************************/
#pragma mark - Helper Methods
/*********************************************************************************/
- (NSURLSessionDataTask *) doDataTask: (NSString*) method
                          retryObject: (APCNetworkRetryObject*) retryObject
                            URLString: (NSString*)URLString
                           parameters:(id)parameters
                           completion:(SBBNetworkManagerCompletionBlock)completion
{
    APCNetworkRetryObject * localRetryObject;
    __weak APCNetworkRetryObject * weakLocalRetryObject;
    if (!retryObject) {
        localRetryObject = [[APCNetworkRetryObject alloc] init];
        weakLocalRetryObject = localRetryObject;
        localRetryObject.completionBlock = completion;
        localRetryObject.retryBlock = ^ {
            __strong APCNetworkRetryObject * strongLocalRetryObject = weakLocalRetryObject; //To break retain cycle
            [self doDataTask:method retryObject:strongLocalRetryObject URLString:URLString parameters:parameters completion:completion];
        };
    }
    else
    {
        localRetryObject = retryObject;
    }
    
    NSMutableURLRequest *request = [self requestWithMethod:method URLString:URLString parameters:parameters error:nil];
    NSURLSessionDataTask *task = [self.mainSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSError * httpError = [NSError generateSBBErrorForHTTPResponse:(NSHTTPURLResponse*)response];
        NSDictionary * responseObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (error)
        {
            [self handleError:error task:task retryObject:localRetryObject];
        }
        else if (httpError)
        {
            //TODO: Add retry for Server maintenance
            if (completion) {
                completion(task, responseObject, httpError);
            }
        }
        else
        {
            if (completion) {
                completion(task, responseObject, nil);
            }
        }
    }];
  
    [task resume];
 
    return task;
    
}

- (NSMutableURLRequest *)requestWithMethod:(NSString *)method
                                 URLString:(NSString *)URLString
                                parameters:(id)parameters
                                     error:(NSError *__autoreleasing *)error
{
    
    NSURL *url = [self URLForRelativeorAbsoluteURLString:URLString];
    NSMutableURLRequest *mutableRequest = [[NSMutableURLRequest alloc] initWithURL:url];
    mutableRequest.HTTPMethod = method;
    
    //TODO: Lower Priority. Switch parameters to part of query if its GET.
    if (parameters) {
        if (![mutableRequest valueForHTTPHeaderField:@"Content-Type"]) {
            NSString *charset = (__bridge NSString *)CFStringConvertEncodingToIANACharSetName(CFStringConvertNSStringEncodingToEncoding(NSUTF8StringEncoding));
            [mutableRequest setValue:[NSString stringWithFormat:@"application/json; charset=%@", charset] forHTTPHeaderField:@"Content-Type"];
        }
        
        [mutableRequest setHTTPBody:[NSJSONSerialization dataWithJSONObject:parameters options:0 error:error]];
    }
    
    return mutableRequest;
}

- (NSURL *) URLForRelativeorAbsoluteURLString: (NSString*) URLString
{
    NSURL *url = [NSURL URLWithString:URLString];
    if ([url.scheme.lowercaseString hasPrefix:@"http"]) {
        return url;
    }
    else
    {
        NSURL * tempURL =[NSURL URLWithString:URLString relativeToURL:[NSURL URLWithString:self.baseURL]];
        return [NSURL URLWithString:[tempURL absoluteString]];
    }
}

/*********************************************************************************/
#pragma mark - Error Handler
/*********************************************************************************/
- (void)handleError:(NSError*)error task:(NSURLSessionDataTask*) task retryObject: (APCNetworkRetryObject*) retryObject
{
    NSInteger errorCode = error.code;
    NSError * apcError = [NSError generateSBBErrorForNSURLError:error isInternetConnected:self.isInternetConnected isServerReachable:self.isServerReachable];
    
    if (!self.isInternetConnected || !self.isServerReachable) {
        if (retryObject.completionBlock)
        {
            retryObject.completionBlock(task, nil, apcError);
        }
        retryObject.retryBlock = nil;
    }
    
    if ([self checkForTemporaryErrors:errorCode])
    {
        
        if (retryObject && retryObject.retryCount < kMaxRetryCount)
        {
            double delayInSeconds = pow(2.0, retryObject.retryCount + 1); //Exponential backoff
            dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
            dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
                retryObject.retryBlock();
                retryObject.retryCount++;
            });
        }
        else
        {
            if (retryObject.completionBlock)
            {
                retryObject.completionBlock(task, nil, apcError);
            }
            retryObject.retryBlock = nil;
        }
    }
}

- (BOOL) checkForTemporaryErrors:(NSInteger) errorCode
{
    return (errorCode == NSURLErrorTimedOut || errorCode == NSURLErrorCannotFindHost || errorCode == NSURLErrorCannotConnectToHost || errorCode == NSURLErrorNotConnectedToInternet || errorCode == NSURLErrorSecureConnectionFailed);
}


/*********************************************************************************/
#pragma mark - Misc
/*********************************************************************************/
- (void)reachabilityChanged: (NSNotification*) notification
{
    //TODO: Figure out what needs to be done here
}

- (void)dealloc
{
    [self.serverReachability stopNotifier];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kReachabilityChangedNotification object:self];
}
@end