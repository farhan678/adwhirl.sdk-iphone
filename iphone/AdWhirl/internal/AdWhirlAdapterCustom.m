/*

 AdWhirlAdapterCustom.m
 
 Copyright 2009 AdMob, Inc.
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 
*/

#import "AdWhirlAdapterCustom.h"
#import "AdWhirlView.h"
#import "AdWhirlLog.h"
#import "AdWhirlConfig.h"
#import "AdWhirlAdNetworkConfig.h"
#import "AdWhirlError.h"
#import "CJSONDeserializer.h"
#import "AdWhirlCustomAdView.h"
#import "AdWhirlAdNetworkAdapter+Helpers.h"
#import "AdWhirlAdNetworkRegistry.h"

@interface AdWhirlAdapterCustom ()

- (BOOL)parseAdData:(NSData *)data error:(NSError **)error;

@property (nonatomic,readonly) CLLocationManager *locationManager;
@property (nonatomic,retain) NSURLConnection *adConnection;
@property (nonatomic,retain) NSURLConnection *imageConnection;
@property (nonatomic,retain) AdWhirlCustomAdView *adView;
@property (nonatomic,retain) AdWhirlWebBrowserController *webBrowserController;

@end


@implementation AdWhirlAdapterCustom

@synthesize adConnection;
@synthesize imageConnection;
@synthesize adView;
@synthesize webBrowserController;

+ (AdWhirlAdNetworkType)networkType {
  return AdWhirlAdNetworkTypeCustom;
}

+ (void)load {
  [[AdWhirlAdNetworkRegistry sharedRegistry] registerClass:self];
}

- (id)initWithAdWhirlDelegate:(id<AdWhirlDelegate>)delegate
                           view:(AdWhirlView *)view
                         config:(AdWhirlConfig *)config
                  networkConfig:(AdWhirlAdNetworkConfig *)netConf {
  self = [super initWithAdWhirlDelegate:delegate
                                   view:view
                                 config:config
                          networkConfig:netConf];
  if (self != nil) {
    adData = [[NSMutableData alloc] init];
    imageData = [[NSMutableData alloc] init];
  }
  return self;
}

- (BOOL)shouldSendExMetric {
  return NO; // since we are getting the ad from the AdWhirl server anyway, no
             // need to send extra metric ping to the same server.
}

- (void)getAd {
  @synchronized(self) {
    if (requesting) return;
    requesting = YES;
  }
  
  NSURL *adRequestBaseURL = nil;
  if ([adWhirlDelegate respondsToSelector:@selector(adWhirlCustomAdURL)]) {
    adRequestBaseURL = [adWhirlDelegate adWhirlCustomAdURL];
  }
  if (adRequestBaseURL == nil) {
    adRequestBaseURL = [NSURL URLWithString:kAdWhirlDefaultCustomAdURL];
  }
  NSString *query;
  if (adWhirlConfig.locationOn) {
    AWLogDebug(@"Allow location access in custom ad");
    CLLocation *location;
    if ([adWhirlDelegate respondsToSelector:@selector(locationInfo)]) {
      location = [adWhirlDelegate locationInfo];
    }
    else {
      location = [self.locationManager location];
    }
    NSString *locationStr = [NSString stringWithFormat:@"%lf,%lf",
                             location.coordinate.latitude,
                             location.coordinate.longitude];
    query = [NSString stringWithFormat:@"?appver=%d&country_code=%@&appid=%@&nid=%@&location=%@&location_timestamp=%lf&uuid=%@",
             kAdWhirlAppVer,
             [[NSLocale currentLocale] localeIdentifier],
             adWhirlConfig.appKey,
             networkConfig.nid,
             locationStr,
             [[NSDate date] timeIntervalSince1970],
             [AdWhirlConfig uniqueId]];
  }
  else {
    AWLogDebug(@"Do not allow location access in custom ad");
    query = [NSString stringWithFormat:@"?appver=%d&country_code=%@&appid=%@&nid=%@&uuid=%@",
             kAdWhirlAppVer,
             [[NSLocale currentLocale] localeIdentifier],
             adWhirlConfig.appKey,
             networkConfig.nid,
             [AdWhirlConfig uniqueId]];
  }
  NSURL *adRequestURL = [NSURL URLWithString:query relativeToURL:adRequestBaseURL];
  AWLogDebug(@"Requesting custom ad at %@", adRequestURL);
  NSURLRequest *adRequest = [NSURLRequest requestWithURL:adRequestURL];
  NSURLConnection *conn = [[NSURLConnection alloc] initWithRequest:adRequest
                                                          delegate:self];
  self.adConnection = conn;
  [conn release];
}

- (CLLocationManager *)locationManager {
  if (locationManager == nil) {
    locationManager = [[CLLocationManager alloc] init];
  }
  return locationManager;
}

- (BOOL)parseEnums:(int *)val
            adInfo:(NSDictionary*)info
            minVal:(int)min
            maxVal:(int)max
         fieldName:(NSString *)name
             error:(NSError **)error {
  NSString *str = [info objectForKey:name];
  if (str == nil) {
    if (error != nil)
      *error = [AdWhirlError errorWithCode:AdWhirlCustomAdDataError
                               description:[NSString stringWithFormat:
                                            @"Custom ad data has no '%@' field", name]];
    return NO;
  }
  int intVal = [str intValue];
  if (intVal <= min || intVal >= max) {
    if (error != nil)
      *error = [AdWhirlError errorWithCode:AdWhirlCustomAdDataError
                               description:[NSString stringWithFormat:
                                            @"Invalid value for %@ - %d", name, intVal]];
    return NO;
  }
  *val = intVal;
  return YES;
}  

- (BOOL)parseAdData:(NSData *)data error:(NSError **)error {
  NSError *jsonError;
  id parsed = [[CJSONDeserializer deserializer] deserialize:data error:&jsonError];
  if (parsed == nil) {
    if (error != nil)
      *error = [AdWhirlError errorWithCode:AdWhirlCustomAdParseError
                               description:@"Error parsing custom ad JSON from server"
                           underlyingError:jsonError];
    return NO;
  }
  if ([parsed isKindOfClass:[NSDictionary class]]) {
    NSDictionary *adInfo = parsed;
    
    // gather up and validate ad info
    NSString *text = [adInfo objectForKey:@"ad_text"];
    NSString *redirectURLStr = [adInfo objectForKey:@"redirect_url"];

    int adTypeInt;
    if (![self parseEnums:&adTypeInt
                   adInfo:adInfo
                   minVal:AWCustomAdTypeMIN
                   maxVal:AWCustomAdTypeMAX
                fieldName:@"ad_type"
                    error:error]) {
      return NO;
    }
    AWCustomAdType adType = adTypeInt;

    int launchTypeInt;
    if (![self parseEnums:&launchTypeInt
                   adInfo:adInfo
                   minVal:AWCustomAdLaunchTypeMIN
                   maxVal:AWCustomAdLaunchTypeMAX
                fieldName:@"launch_type"
                    error:error]) {
      return NO;
    }
    AWCustomAdLaunchType launchType = launchTypeInt;

    int animTypeInt;
    if (![self parseEnums:&animTypeInt
                   adInfo:adInfo
                   minVal:AWCustomAdWebViewAnimTypeMIN
                   maxVal:AWCustomAdWebViewAnimTypeMAX
                fieldName:@"webview_animation_type"
                    error:error]) {
      return NO;
    }
    AWCustomAdWebViewAnimType animType = animTypeInt;
    
    NSURL *redirectURL = nil;
    if (redirectURLStr == nil) {
      AWLogWarn(@"No redirect URL for custom ad");
    }
    else {
      redirectURL = [[NSURL alloc] initWithString:redirectURLStr];
      if (!redirectURL)
        AWLogWarn(@"Malformed redirect URL string %@", redirectURLStr);
    }
    
    NSString *clickMetricsURLStr = [adInfo objectForKey:@"metrics_url"];
    NSURL *clickMetricsURL = nil;
    if (clickMetricsURLStr == nil) {
      AWLogWarn(@"No click metric URL for custom ad");
    }
    else {
      clickMetricsURL = [[NSURL alloc] initWithString:clickMetricsURLStr];
      if (!clickMetricsURL)
        AWLogWarn(@"Malformed click metrics URL string %@", clickMetricsURLStr);
    }
    
    AWLogDebug(@"Got custom ad %@ %@ %@ %d %d %d", text, redirectURL,
               clickMetricsURL, adType, launchType, animType);
    
    self.adView = [[AdWhirlCustomAdView alloc] initWithDelegate:self
                                                           text:text
                                                    redirectURL:redirectURL
                                                clickMetricsURL:clickMetricsURL
                                                         adType:adType
                                                     launchType:launchType
                                                       animType:animType
                                                backgroundColor:adWhirlConfig.backgroundColor
                                                      textColor:adWhirlConfig.textColor];
    [redirectURL release];
    [clickMetricsURL release];
    if (adView == nil) {
      if (error != nil)
        *error = [AdWhirlError errorWithCode:AdWhirlCustomAdDataError
                                 description:@"Error initializing AdWhirl custom ad view"];
      return NO;
    }      

    // fetch image
    NSString * imageURL = [adInfo objectForKey:@"img_url"];
    AWLogDebug(@"Request custom ad image at %@", imageURL);
    NSURLRequest *imageRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:imageURL]];
    NSURLConnection *conn = [[NSURLConnection alloc] initWithRequest:imageRequest
                                                            delegate:self];
    self.imageConnection = conn;
    [conn release];
  }
  else {
    if (error != nil)
      *error = [AdWhirlError errorWithCode:AdWhirlCustomAdDataError
                               description:@"Expected top-level dictionary in custom ad data"];
    return NO;
  }
  return YES;
}

- (void)dealloc {
  [locationManager release], locationManager = nil;
  [adConnection release], adConnection = nil;
  [adData release], adData = nil;
  [imageConnection release], imageConnection = nil;
  [imageData release], imageData = nil;
  [adView release], adView = nil;
  [webBrowserController release], webBrowserController = nil;
  [super dealloc];
}

#pragma mark NSURLConnection delegate methods.

- (void)connection:(NSURLConnection *)conn didReceiveResponse:(NSURLResponse *)response {
  if (conn == adConnection) {
    [adData setLength:0];
  }
  else if (conn == imageConnection) {
    [imageData setLength:0];
  }
}

- (void)connection:(NSURLConnection *)conn didFailWithError:(NSError *)error {
  if (conn == adConnection) {
    [adWhirlView adapter:self didFailAd:[AdWhirlError errorWithCode:AdWhirlCustomAdConnectionError
                                                   description:@"Error connecting to custom ad server"
                                               underlyingError:error]];
    requesting = NO;
  }
  else if (conn == imageConnection) {
    [adWhirlView adapter:self didFailAd:[AdWhirlError errorWithCode:AdWhirlCustomAdConnectionError
                                                        description:@"Error connecting to fetch image"
                                                    underlyingError:error]];
    requesting = NO;
  }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)conn {
  if (conn == adConnection) {
    NSError *error;
    if (![self parseAdData:adData error:&error]) {
      [adWhirlView adapter:self didFailAd:error];
      requesting = NO;
      return;
    }
  }
  else if (conn == imageConnection) {
    UIImage *image = [[UIImage alloc] initWithData:imageData];
    if (image == nil) {
      [adWhirlView adapter:self didFailAd:[AdWhirlError errorWithCode:AdWhirlCustomAdImageError
                                                          description:@"Cannot initialize image from data"]];
      requesting = NO;
      return;
    }
    adView.image = image;
    [adView setNeedsDisplay];
    [image release];
    requesting = NO;
    [adWhirlView adapter:self didReceiveAdView:self.adView];
  }
}

- (void)connection:(NSURLConnection *)conn didReceiveData:(NSData *)data {
  if (conn == adConnection) {
    [adData appendData:data];
  }
  else if (conn == imageConnection) {
    [imageData appendData:data];
  }
}

#pragma mark AdWhirlCustomAdViewDelegate methods

- (void)adTapped:(AdWhirlCustomAdView *)ad {
  if (ad != adView) return;
  if (ad.clickMetricsURL != nil) {
    NSURLRequest *metRequest = [NSURLRequest requestWithURL:ad.clickMetricsURL];
    [NSURLConnection connectionWithRequest:metRequest
                                  delegate:nil]; // fire and forget
  }
  if (ad.redirectURL == nil) {
    AWLogError(@"Custom ad redirect URL is nil");
    return;
  }
  switch (ad.launchType) {
    case AWCustomAdLaunchTypeSafari:
      [[UIApplication sharedApplication] openURL:ad.redirectURL];
      break;
    case AWCustomAdLaunchTypeCanvas:
      if (self.webBrowserController == nil) {
        AdWhirlWebBrowserController *ctrlr = [[AdWhirlWebBrowserController alloc] init];
        self.webBrowserController = ctrlr;
        [ctrlr release];
      }
      webBrowserController.delegate = self;
      [webBrowserController showInWindow:ad.window transition:ad.animType];
      webBrowserController.toolBar.tintColor = ad.backgroundColor;
      [self helperNotifyDelegateOfFullScreenModal];
      [webBrowserController loadURL:ad.redirectURL];
      break;
    default:
      AWLogError(@"Unsupported launch type %d", ad.launchType);
      break;
  }
}

#pragma mark AdWhirlWebBrowserControllerDelegate methods

- (void)webBrowserClosed:(AdWhirlWebBrowserController *)controller {
  if (controller != webBrowserController) return;
  self.webBrowserController = nil; // don't keep around to save memory
  [self helperNotifyDelegateOfFullScreenModalDismissal];
}

@end
