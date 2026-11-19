// Copyright 2024 LiveKit, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;

// ignore: implementation_imports
import 'package:dart_webrtc/src/frame_cryptor_impl.dart' show FrameCryptorFactoryImpl;
import 'package:logging/logging.dart' show Level;
import 'package:web/web.dart' as web;

import '../../logger.dart';
import '../platform.dart';

PlatformType lkPlatformImplementation() => PlatformType.web;

bool lkPlatformIsWebMobileImplementation() {
  return (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);
}

bool lkE2EESupportedImplementation() {
  return isInsertableStreamSupported() || isScriptTransformSupported();
}

bool lkPlatformIsTestImplementation() => false;

bool _forwardingE2EEWorkerLogs = false;

void lkForwardE2EEWorkerLogsImplementation() {
  if (_forwardingE2EEWorkerLogs) return;
  _forwardingE2EEWorkerLogs = true;
  // The check flutter_webrtc uses to pick the API.
  final scriptTransform = web.window.hasProperty('RTCRtpScriptTransform'.toJS).toDart;
  logger.info('E2EE frames go through ${scriptTransform ? 'RTCRtpScriptTransform' : 'createEncodedStreams'}');
  // This page's worker only, which flutter_webrtc creates here. Its messages are
  // delivered after this task, so none are missed.
  FrameCryptorFactoryImpl.instance.worker.addEventListener(
    'message',
    (web.MessageEvent event) {
      final data = event.data.dartify();
      if (data is! Map || data['type'] != 'log') return;
      final value = (data['level'] as num).toInt();
      logger.log(
        Level.LEVELS.firstWhere((level) => level.value == value, orElse: () => Level.INFO),
        data['message'],
      );
    }.toJS,
  );
}

bool isScriptTransformSupported() {
  return web.window.hasProperty('RTCRtpScriptTransform'.toJS).isDefinedAndNotNull;
}

bool isInsertableStreamSupported() {
  return web.window.hasProperty('RTCRtpSender'.toJS).isDefinedAndNotNull &&
      ((web.window.getProperty('RTCRtpSender'.toJS) as JSObject).getProperty(
                'prototype'.toJS,
              )
              as JSObject)
          .getProperty('createEncodedStreams'.toJS)
          .isDefinedAndNotNull;
}

BrowserType lkBrowserImplementation() {
  final ua = web.window.navigator.userAgent;
  final vendor = web.window.navigator.vendor;
  final appVersion = web.window.navigator.appVersion;
  if (web.window.navigator.vendor.contains('Google')) {
    return BrowserType.chrome;
  }
  if (ua.contains('Firefox')) return BrowserType.firefox;
  if (vendor.contains('Apple') && appVersion.contains('Version')) {
    return BrowserType.safari;
  }
  if (web.Device.isIE) return BrowserType.internetExplorer;
  if (ua.contains('Edg/')) return BrowserType.edge;
  if (web.Device.isWebKit) return BrowserType.wkWebView;
  return BrowserType.unknown;
}

BrowserVersion lkBrowserVersionImplementation() {
  final ua = web.window.navigator.userAgent;
  final appVersion = web.window.navigator.appVersion;

  BrowserVersion chromeBased(String prefix) {
    final Match? match = RegExp(prefix + r'/(\d+)\.(\d+)\.(\d+)\.(\d+)').firstMatch(appVersion);
    if (match == null) {
      return BrowserVersion(0, 0, 0);
    }

    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2)!);
    final patch = int.parse(match.group(3)!);
    return BrowserVersion(major, minor, patch);
  }

  switch (lkBrowserImplementation()) {
    case BrowserType.chrome:
      return chromeBased('Chrome');
    case BrowserType.firefox:
      final Match? match = RegExp(r'rv:(\d+)\.(\d+)\)').firstMatch(ua);
      if (match == null) {
        return BrowserVersion(0, 0, 0);
      }

      final major = int.parse(match.group(1)!);
      final minor = int.parse(match.group(2)!);
      return BrowserVersion(major, minor, 0);
    case BrowserType.safari:
      final Match? match = RegExp(r'Version/(\d+)(\.(\d+))?(\.(\d+))?').firstMatch(appVersion);
      if (match == null) {
        return BrowserVersion(0, 0, 0);
      }

      final major = int.parse(match.group(1)!);
      final minor = int.parse(match.group(3) ?? '0');
      final patch = int.parse(match.group(5) ?? '0');
      return BrowserVersion(major, minor, patch);
    case BrowserType.internetExplorer:
      Match? match = RegExp(r'MSIE (\d+)\.(\d+);').firstMatch(appVersion);
      if (match != null) {
        final major = int.parse(match.group(1)!);
        final minor = int.parse(match.group(2)!);
        return BrowserVersion(major, minor, 0);
      }

      match = RegExp(r'rv[: ](\d+)\.(\d+)').firstMatch(appVersion);
      if (match != null) {
        final major = int.parse(match.group(1)!);
        final minor = int.parse(match.group(2)!);
        return BrowserVersion(major, minor, 0);
      }

      match = RegExp(r'Edge/(\d+)\.(\d+)$').firstMatch(appVersion);
      if (match != null) {
        final major = int.parse(match.group(1)!);
        final minor = int.parse(match.group(2)!);
        return BrowserVersion(major, minor, 0);
      }

      return BrowserVersion(0, 0, 0);
    case BrowserType.wkWebView:
      final Match? match = RegExp(r'AppleWebKit/(\d+)\.(\d+)\.(\d+)').firstMatch(appVersion);
      if (match == null) {
        return BrowserVersion(0, 0, 0);
      }

      final major = int.parse(match.group(1)!);
      final minor = int.parse(match.group(2)!);
      final patch = int.parse(match.group(3)!);
      return BrowserVersion(major, minor, patch);
    case BrowserType.edge:
      return chromeBased('Edg');
    default:
      return BrowserVersion(0, 0, 0);
  }
}
