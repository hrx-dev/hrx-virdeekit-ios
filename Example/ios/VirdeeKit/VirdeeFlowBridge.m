//
// VirdeeFlowBridge.m
// VirdeeKit
//
// Created by Oleksandr Malinchuk on 31.07.2026
// Copyright © 2026 Hard Rock Experience Limited. All rights reserved.
//

#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

// Objective-C registration for the Swift native modules. The selector names here
// must match the @objc(...) names in VirdeeFlowBridge.swift and the call sites in
// Example/index.js.

@interface RCT_EXTERN_MODULE(VirdeeFlowBridge, NSObject)

RCT_EXTERN_METHOD(failedToStart:(NSDictionary *)payload)
RCT_EXTERN_METHOD(setRequirements:(NSDictionary *)summary)
RCT_EXTERN_METHOD(showVerifyIdButton:(NSString *)accessGrantId)
RCT_EXTERN_METHOD(showClearIDV:(NSString *)accessGrantId)
RCT_EXTERN_METHOD(closeClearIDV)
RCT_EXTERN_METHOD(showMobileKeyButton)
RCT_EXTERN_METHOD(closeMobileKey)

RCT_EXTERN_METHOD(onVirdeeEvent:(NSString *)flow
                  event:(NSString *)event
                  payload:(NSDictionary *)payload)

RCT_EXTERN_METHOD(log:(NSString *)level message:(NSString *)message)

@end

@interface RCT_EXTERN_MODULE(VirdeeRestartEmitter, RCTEventEmitter)
@end
