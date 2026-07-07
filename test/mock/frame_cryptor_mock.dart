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

import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'e2ee_fake_manager.dart' show TestKeyProvider;

/// In-memory [rtc.FrameCryptor] that records calls made by `E2EEManager`.
class FakeFrameCryptor extends rtc.FrameCryptor {
  FakeFrameCryptor(this._participantId);

  final String _participantId;

  bool? lastEnabled;
  int? lastKeyIndex;
  final List<String> updatedCodecs = [];
  bool disposed = false;

  @override
  String get participantId => _participantId;

  @override
  Future<bool> setEnabled(bool enabled) async {
    lastEnabled = enabled;
    return true;
  }

  @override
  Future<bool> get enabled async => lastEnabled ?? false;

  @override
  Future<bool> setKeyIndex(int index) async {
    lastKeyIndex = index;
    return true;
  }

  @override
  Future<int> get keyIndex async => lastKeyIndex ?? 0;

  @override
  Future<void> updateCodec(String codec) async {
    updatedCodecs.add(codec);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// [rtc.FrameCryptorFactory] that returns [FakeFrameCryptor]s and records them.
class FakeFrameCryptorFactory implements rtc.FrameCryptorFactory {
  final List<FakeFrameCryptor> senderCryptors = [];
  final List<FakeFrameCryptor> receiverCryptors = [];

  @override
  Future<rtc.KeyProvider> createDefaultKeyProvider(rtc.KeyProviderOptions options) async => TestKeyProvider();

  @override
  Future<rtc.FrameCryptor> createFrameCryptorForRtpSender({
    required String participantId,
    required rtc.RTCRtpSender sender,
    required rtc.Algorithm algorithm,
    required rtc.KeyProvider keyProvider,
  }) async {
    final cryptor = FakeFrameCryptor(participantId);
    senderCryptors.add(cryptor);
    return cryptor;
  }

  @override
  Future<rtc.FrameCryptor> createFrameCryptorForRtpReceiver({
    required String participantId,
    required rtc.RTCRtpReceiver receiver,
    required rtc.Algorithm algorithm,
    required rtc.KeyProvider keyProvider,
  }) async {
    final cryptor = FakeFrameCryptor(participantId);
    receiverCryptors.add(cryptor);
    return cryptor;
  }
}

/// No-op [rtc.DataPacketCryptor] so `E2EEManager.setup` does not hit the
/// platform channel in tests.
class FakeDataPacketCryptor implements rtc.DataPacketCryptor {
  @override
  Future<rtc.EncryptedPacket> encrypt({
    required String participantId,
    required int keyIndex,
    required Uint8List data,
  }) async =>
      rtc.EncryptedPacket(data: data, keyIndex: keyIndex, iv: Uint8List(12));

  @override
  Future<Uint8List> decrypt({
    required String participantId,
    required rtc.EncryptedPacket encryptedPacket,
  }) async =>
      encryptedPacket.data;

  @override
  Future<void> dispose() async {}
}

class FakeDataPacketCryptorFactory implements rtc.DataPacketCryptorFactory {
  @override
  Future<rtc.DataPacketCryptor> createDataPacketCryptor({
    required rtc.Algorithm algorithm,
    required rtc.KeyProvider keyProvider,
  }) async =>
      FakeDataPacketCryptor();
}
