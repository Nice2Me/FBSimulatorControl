/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBSimulatorApplicationCommands.h"

#import <CoreSimulator/SimDevice.h>

#import <FBControlCore/FBControlCore.h>

#import "FBSimulator.h"
#import "FBSimulator+Helpers.h"
#import "FBSimulatorError.h"
#import "FBApplicationLaunchStrategy.h"
#import "FBSimulatorSubprocessTerminationStrategy.h"
#import "FBSimulatorInteraction.h"
#import "FBSimulatorInteraction+Applications.h"

@interface FBSimulatorApplicationCommands ()

@property (nonatomic, weak, readonly) FBSimulator *simulator;

@end

BOOL deleteDirectory(NSURL *path);
BOOL isApplicationAtPath(NSString *path);
NSString *pathToApplicationAt(NSString *path, NSURL **tempDirURLPtr, NSError **error);


@implementation FBSimulatorApplicationCommands

+ (instancetype)withSimulator:(FBSimulator *)simulator
{
  return [[self alloc] initWithSimulator:simulator];
}

- (instancetype)initWithSimulator:(FBSimulator *)simulator
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _simulator = simulator;
  return self;
}

#pragma mark FBApplicationCommands Implementation

- (BOOL)installApplicationWithPath:(NSString *)path error:(NSError **)error
{
  NSError *innerError = nil;
  NSURL *tempDirURL = nil;

  NSString *appPath = pathToApplicationAt(path, &tempDirURL, &innerError);
  if (appPath == nil) {
    return [[FBSimulatorError causedBy:innerError] failBool:error];
  }

  BOOL installResult = [self installExtractedApplicationWithPath:appPath error:&innerError];
  if (tempDirURL != nil) {
    deleteDirectory(tempDirURL);
  }
  return installResult;
}
- (BOOL)uninstallApplicationWithBundleID:(NSString *)bundleID error:(NSError **)error
{
  NSParameterAssert(bundleID);

  // Confirm the app is suitable to be uninstalled.
  if ([self.simulator isSystemApplicationWithBundleID:bundleID error:nil]) {
    return [[[FBSimulatorError
              describeFormat:@"Can't uninstall '%@' as it is a system Application", bundleID]
             inSimulator:self.simulator]
            failBool:error];
  }
  NSError *innerError = nil;
  if (![self.simulator installedApplicationWithBundleID:bundleID error:&innerError]) {
    return [[[[FBSimulatorError
               describeFormat:@"Can't uninstall '%@' as it isn't installed", bundleID]
              causedBy:innerError]
             inSimulator:self.simulator]
            failBool:error];
  }
  // Kill the app if it's running
  [[self.simulator.interact terminateApplicationWithBundleID:bundleID] perform:nil];
  // Then uninstall for real.
  if (![self.simulator.device uninstallApplication:bundleID withOptions:nil error:&innerError]) {
    return [[[[FBSimulatorError
               describeFormat:@"Failed to uninstall '%@'", bundleID]
              causedBy:innerError]
             inSimulator:self.simulator]
            failBool:error];
  }
  return YES;
}

- (BOOL)isApplicationInstalledWithBundleID:(NSString *)bundleID error:(NSError **)error
{
  return [self.simulator installedApplicationWithBundleID:bundleID error:error] != nil;
}

- (BOOL)launchApplication:(FBApplicationLaunchConfiguration *)configuration error:(NSError **)error
{
  return [[FBApplicationLaunchStrategy withSimulator:self.simulator] launchApplication:configuration error:error] != nil;
}

- (BOOL)killApplicationWithBundleID:(NSString *)bundleID error:(NSError **)error
{
  NSError *innerError = nil;
  FBProcessInfo *process = [self.simulator runningApplicationWithBundleID:bundleID error:&innerError];
  if (!process) {
    return [[[[FBSimulatorError
      describeFormat:@"Could not find a running application for '%@'", bundleID]
      inSimulator:self.simulator]
      causedBy:innerError]
      failBool:error];
  }
  if (![[FBSimulatorSubprocessTerminationStrategy forSimulator:self.simulator] terminate:process error:&innerError]) {
    return [FBSimulatorError failBoolWithError:innerError errorOut:error];
  }

  return YES;
}

- (NSArray<FBApplicationDescriptor *> *)installedApplications
{
  NSMutableArray<FBApplicationDescriptor *> *applications = [NSMutableArray array];
  for (NSDictionary *appInfo in [[self.simulator.device installedAppsWithError:nil] allValues]) {
    FBApplicationDescriptor *application = [FBApplicationDescriptor applicationWithPath:appInfo[ApplicationPathKey] installTypeString:appInfo[ApplicationTypeKey] error:nil];
    if (!application) {
      continue;
    }
    [applications addObject:application];
  }
  return [applications copy];
}

- (BOOL)installExtractedApplicationWithPath:(NSString *)path error:(NSError **)error
{
  NSError *innerError = nil;

  FBApplicationDescriptor *application = [FBApplicationDescriptor userApplicationWithPath:path error:&innerError];
  if (!application) {
    return [[[FBSimulatorError
      describeFormat:@"Could not determine Application information for path %@", path]
      causedBy:innerError]
      failBool:error];
  }

  if ([self.simulator isSystemApplicationWithBundleID:application.bundleID error:nil]) {
    return YES;
  }

  NSSet<NSString *> *binaryArchitectures = application.binary.architectures;
  NSSet<NSString *> *supportedArchitectures = FBControlCoreConfigurationVariants.baseArchToCompatibleArch[self.simulator.deviceConfiguration.simulatorArchitecture];
  if (![binaryArchitectures intersectsSet:supportedArchitectures]) {
    return [[FBSimulatorError
      describeFormat:
        @"Simulator does not support any of the architectures (%@) of the executable at %@. Simulator Archs (%@)",
        [FBCollectionInformation oneLineDescriptionFromArray:binaryArchitectures.allObjects],
        application.binary.path,
        [FBCollectionInformation oneLineDescriptionFromArray:supportedArchitectures.allObjects]]
      failBool:error];
  }

  NSDictionary *options = @{
    @"CFBundleIdentifier" : application.bundleID
  };
  NSURL *appURL = [NSURL fileURLWithPath:application.path];

  if (![self.simulator.device installApplication:appURL withOptions:options error:&innerError]) {
    return [[[FBSimulatorError
      describeFormat:@"Failed to install Application %@ with options %@", application, options]
      causedBy:innerError]
      failBool:error];
  }

  return YES;
}

@end

BOOL deleteDirectory(NSURL *path)
{
  if (path == nil) {
    return YES;
  }
  return [[NSFileManager defaultManager] removeItemAtURL:path error:nil];
}

BOOL isApplicationAtPath(NSString *path)
{
  BOOL isDirectory = NO;
  return
    path != nil &&
    [path hasSuffix:@".app"] &&
    [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] &&
    isDirectory;
}

NSString *pathToApplicationAt(NSString *path, NSURL **tempDirURLPtr, NSError **error)
{
  if (isApplicationAtPath(path)) {
    return path;
  }

  NSError *innerError = nil;

  NSURL *tempDirURL = [NSURL fileURLWithPath:
    [NSTemporaryDirectory() stringByAppendingPathComponent:
      [[NSProcessInfo processInfo] globallyUniqueString]]
    isDirectory:YES];
  *tempDirURLPtr = tempDirURL;

  if (![[NSFileManager defaultManager]
        createDirectoryAtURL:tempDirURL withIntermediateDirectories:YES attributes:nil error:&innerError]) {
    [[[FBSimulatorError
      describe:@"Could not create temporary directory for IPA extraction"]
      causedBy:innerError]
      fail:error];
    return nil;
  }
  FBTask *task = [[[[[FBTaskBuilder withLaunchPath:@"/usr/bin/unzip"]
    withArguments:@[path, @"-d", [tempDirURL path]]]
    withAcceptableTerminationStatusCodes:[NSSet setWithObject:@0]]
    build]
    startSynchronouslyWithTimeout:[FBControlCoreGlobalConfiguration regularTimeout]];

  if (task.error) {
    [[[FBSimulatorError
      describeFormat:@"Could not unzip IPA at %@.", path]
      causedBy:task.error]
      fail:error];
    return nil;
  }

  NSDirectoryEnumerator *directoryEnumerator = [[NSFileManager defaultManager]
    enumeratorAtURL:tempDirURL
    includingPropertiesForKeys:@[NSURLIsDirectoryKey]
    options:0
    errorHandler:nil];
  NSSet *applicationURLs = [NSSet set];
  for (NSURL *fileURL in directoryEnumerator) {
    if (isApplicationAtPath([fileURL path])) {
      applicationURLs = [applicationURLs setByAddingObject:fileURL];
    }
  }
  if ([applicationURLs count] != 1) {
    [[FBSimulatorError
      describeFormat:@"Expected only one Application in IPA, found %lu", [applicationURLs count]]
     fail:error];
    deleteDirectory(tempDirURL);
    return nil;
  }
  return [[applicationURLs anyObject] path];
}
