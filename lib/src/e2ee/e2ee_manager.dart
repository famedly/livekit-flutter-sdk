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

import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:meta/meta.dart';

import '../core/room.dart';
import '../events.dart';
import '../extensions.dart';
import '../logger.dart';
import '../managers/event.dart';
import '../utils.dart';
import 'events.dart';
import 'key_provider.dart';
import 'options.dart';

class E2EEManager {
  Room? _room;
  final Map<Map<String, String>, FrameCryptor> _frameCryptors = {};
  final BaseKeyProvider _keyProvider;
  final Algorithm _algorithm = Algorithm.kAesGcm;
  DataPacketCryptor? _dataPacketCryptor;
  bool _enabled = true;
  bool _encryptionEnabled = false;
  EventsListener<RoomEvent>? _listener;

  /// The factory used to create [FrameCryptor]s. Overridable for testing.
  @visibleForTesting
  FrameCryptorFactory cryptorFactory = frameCryptorFactory;

  /// The factory used to create the [DataPacketCryptor]. Overridable for testing.
  @visibleForTesting
  DataPacketCryptorFactory dataCryptorFactory = dataPacketCryptorFactory;

  E2EEManager(this._keyProvider, {bool dcEncryptionEnabled = false}) {
    _encryptionEnabled = dcEncryptionEnabled;
  }

  Future<void> setup(Room room) async {
    if (_room != room) {
      await _cleanUp();
      _room = room;
      _listener = _room!.createListener();
      _listener!
        ..on<LocalTrackPublishedEvent>((event) async {
          try {
            await _setupFrameCryptorForLocalTrack(event);
          } catch (error) {
            logger.warning(
                'E2EEManager: failed to set up frame cryptor for local track ${event.publication.sid}: $error');
          }
        })
        ..on<LocalTrackUnpublishedEvent>((event) async {
          for (var key in _frameCryptors.keys.toList()) {
            if (key.keys.first == event.participant.identity && key.values.first == event.publication.sid) {
              final frameCryptor = _frameCryptors.remove(key);
              await frameCryptor?.setEnabled(false);
              await frameCryptor?.dispose();
            }
          }
        })
        ..on<TrackSubscribedEvent>((event) async {
          try {
            await _setupFrameCryptorForRemoteTrack(event);
          } catch (error) {
            logger.warning(
                'E2EEManager: failed to set up frame cryptor for remote track ${event.publication.sid}: $error');
          }
        })
        ..on<TrackUnsubscribedEvent>((event) async {
          for (var key in _frameCryptors.keys.toList()) {
            if (key.keys.first == event.participant.identity && key.values.first == event.publication.sid) {
              final frameCryptor = _frameCryptors.remove(key);
              await frameCryptor?.setEnabled(false);
              await frameCryptor?.dispose();
            }
          }
        });
      _dataPacketCryptor ??= await dataCryptorFactory.createDataPacketCryptor(
          algorithm: _algorithm, keyProvider: _keyProvider.keyProvider);
    }
  }

  /// Extracts the codec part of a mime type (e.g. `vp8` for `video/VP8`).
  /// Returns an empty string when the mime type is absent or malformed.
  static String _codecFromMimeType(String mimeType) {
    final parts = mimeType.split('/');
    return parts.length == 2 ? parts[1].toLowerCase() : '';
  }

  Future<void> _setupFrameCryptorForLocalTrack(LocalTrackPublishedEvent event) async {
    if (event.publication.encryptionType == EncryptionType.kNone || isAV1Codec(event.publication.track?.codec ?? '')) {
      // no need to setup frame cryptor
      return;
    }
    final frameCryptor = await _addRtpSender(
        sender: event.publication.track!.sender!, identity: event.participant.identity, sid: event.publication.sid);
    // Attach the state callback before any await that may throw so E2EE state
    // changes are always surfaced.
    frameCryptor.onFrameCryptorStateChanged = (trackId, state) {
      if (kDebugMode) {
        print('Sender::onFrameCryptorStateChanged: $state, trackId:  $trackId');
      }
      final participant = event.participant;
      [event.participant.events, participant.room.events].emit(TrackE2EEStateEvent(
        participant: participant,
        publication: event.publication,
        state: _e2eeStateFromFrameCryptoState(state),
      ));
    };
    if (kIsWeb && event.publication.track!.codec != null) {
      await frameCryptor.updateCodec(event.publication.track!.codec!);
    }
  }

  Future<void> _setupFrameCryptorForRemoteTrack(TrackSubscribedEvent event) async {
    final publication = event.publication;
    final participant = event.participant;
    final listenerAtStart = _listener;

    // A track can be subscribed before its TrackInfo metadata (mimeType /
    // encryption) has been applied to the publication. Deciding on that
    // incomplete metadata used to either throw (`mimeType.split('/')[1]` on an
    // empty mime type) or wrongly skip the frame cryptor, so the track stayed
    // encrypted forever (black video / silent audio). Wait for the metadata to
    // arrive before deciding.
    final timeout = participant.room.connectOptions.timeouts.publish;
    final deadline = DateTime.now().add(timeout);
    var codec = _codecFromMimeType(publication.mimeType);
    while ((codec.isEmpty || publication.latestInfo == null) && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 200));
      // Manager was cleaned up, or the track was unsubscribed / replaced while
      // waiting; a newer subscription will run its own setup.
      if (!identical(_listener, listenerAtStart) || !identical(publication.track, event.track)) {
        return;
      }
      codec = _codecFromMimeType(publication.mimeType);
    }

    if (publication.encryptionType == EncryptionType.kNone || isAV1Codec(codec)) {
      // no need to setup frame cryptor
      logger.info('E2EEManager: not setting up frame cryptor for ${publication.sid}'
          ' (mimeType: "${publication.mimeType}", encryption: ${publication.encryptionType})');
      return;
    }
    if (codec.isEmpty) {
      logger.warning('E2EEManager: no mimeType for encrypted track ${publication.sid} after $timeout,'
          ' setting up frame cryptor without codec');
    }

    final frameCryptor = await _addRtpReceiver(
      receiver: event.track.receiver!,
      identity: participant.identity,
      sid: publication.sid,
    );
    // Attach the state callback before any await that may throw so E2EE state
    // changes are always surfaced.
    frameCryptor.onFrameCryptorStateChanged = (trackId, state) {
      if (kDebugMode) {
        print('Receiver::onFrameCryptorStateChanged: $state, trackId: $trackId');
      }
      [participant.events, participant.room.events].emit(TrackE2EEStateEvent(
        participant: participant,
        publication: publication,
        state: _e2eeStateFromFrameCryptoState(state),
      ));
    };
    if (kIsWeb && codec.isNotEmpty) {
      await frameCryptor.updateCodec(codec);
    }
  }

  BaseKeyProvider get keyProvider => _keyProvider;

  Future<void> ratchetKey({String? participantId, int? keyIndex}) async {
    if (participantId != null) {
      await _keyProvider.ratchetKey(participantId, keyIndex);
    } else {
      await _keyProvider.ratchetSharedKey(keyIndex: keyIndex);
    }
  }

  Future<void> _cleanUp() async {
    await _listener?.cancelAll();
    await _listener?.dispose();
    _listener = null;
    for (var frameCryptor in _frameCryptors.values.toList()) {
      await frameCryptor.dispose();
    }
    _frameCryptors.clear();

    await _dataPacketCryptor?.dispose();
    _dataPacketCryptor = null;
  }

  Future<FrameCryptor> _addRtpSender(
      {required RTCRtpSender sender, required String identity, required String sid}) async {
    final frameCryptor = await cryptorFactory.createFrameCryptorForRtpSender(
        participantId: identity, sender: sender, algorithm: _algorithm, keyProvider: _keyProvider.keyProvider);
    _frameCryptors[{identity: sid}] = frameCryptor;
    await frameCryptor.setEnabled(_enabled);
    logger.info('_addRtpSender, setKeyIndex: ${_keyProvider.getLatestIndex(identity)}');
    await frameCryptor.setKeyIndex(_keyProvider.getLatestIndex(identity));
    return frameCryptor;
  }

  Future<FrameCryptor> _addRtpReceiver(
      {required RTCRtpReceiver receiver, required String identity, required String sid}) async {
    final frameCryptor = await cryptorFactory.createFrameCryptorForRtpReceiver(
        participantId: identity, receiver: receiver, algorithm: _algorithm, keyProvider: _keyProvider.keyProvider);
    _frameCryptors[{identity: sid}] = frameCryptor;
    await frameCryptor.setEnabled(_enabled);
    logger.info('_addRtpReceiver, setKeyIndex: ${_keyProvider.getLatestIndex(identity)}');
    await frameCryptor.setKeyIndex(_keyProvider.getLatestIndex(identity));
    return frameCryptor;
  }

  /// Enable/Disable frame crypto for the sender and receiver.
  /// @param enabled true to enable, false to disable
  /// if false, the frame cryptor will pass through frames and
  /// without encryption/decryption
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    for (var frameCryptor in _frameCryptors.entries.toList()) {
      await frameCryptor.value.setEnabled(enabled);
    }
  }

  /// Sets the key index for the encryptors of the participant.
  /// @param keyIndex the key index to set
  /// @param participantIdentity the identity of the participant,
  /// if null, use local participant.
  Future<void> setKeyIndex(int keyIndex, {String? participantIdentity}) async {
    participantIdentity ??= _room?.localParticipant?.identity;
    for (var item in _frameCryptors.entries.toList()) {
      if (item.key.keys.first == participantIdentity) {
        await item.value.setKeyIndex(keyIndex);
      }
    }
  }

  /// Get the key index for the encryptors of the participant.
  /// @param identity the identity of the participant,
  /// if null, use local participant.
  /// @return the key index and -1 if not found
  Future<int> getKeyIndex(String? participantIdentity) async {
    participantIdentity ??= _room?.localParticipant?.identity;
    for (var item in _frameCryptors.entries.toList()) {
      if (item.key.keys.first == participantIdentity) {
        return await item.value.keyIndex;
      }
    }
    return -1;
  }

  E2EEState _e2eeStateFromFrameCryptoState(FrameCryptorState state) {
    switch (state) {
      case FrameCryptorState.FrameCryptorStateNew:
        return E2EEState.kNew;
      case FrameCryptorState.FrameCryptorStateOk:
        return E2EEState.kOk;
      case FrameCryptorState.FrameCryptorStateMissingKey:
        return E2EEState.kMissingKey;
      case FrameCryptorState.FrameCryptorStateEncryptionFailed:
        return E2EEState.kEncryptionFailed;
      case FrameCryptorState.FrameCryptorStateDecryptionFailed:
        return E2EEState.kDecryptionFailed;
      case FrameCryptorState.FrameCryptorStateInternalError:
        return E2EEState.kInternalError;
      case FrameCryptorState.FrameCryptorStateKeyRatcheted:
        return E2EEState.kKeyRatcheted;
    }
  }

  bool get isDataChannelEncryptionEnabled => _enabled && _encryptionEnabled;

  Future<Uint8List?> handleEncryptedData({
    required Uint8List data,
    required Uint8List iv,
    required String participantIdentity,
    required int keyIndex,
  }) async {
    if (_dataPacketCryptor == null) {
      throw Exception('DataPacketCryptor is not initialized');
    }
    try {
      final decryptedData = await _dataPacketCryptor!.decrypt(
        participantId: participantIdentity,
        encryptedPacket: EncryptedPacket(data: data, keyIndex: keyIndex, iv: iv),
      );
      return decryptedData;
    } catch (e) {
      logger.warning('handleEncryptedData error: $e');
      return null;
    }
  }

  Future<EncryptedPacket> encryptData({required Uint8List data}) async {
    final participantId = _room?.localParticipant?.identity;
    if (participantId == null || _dataPacketCryptor == null) {
      throw Exception('DataPacketCryptor is not initialized');
    }
    return await _dataPacketCryptor!
        .encrypt(participantId: participantId, keyIndex: _keyProvider.getLatestIndex(participantId), data: data);
  }
}
