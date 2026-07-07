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

@Timeout(Duration(seconds: 5))
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:logging/logging.dart';

import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_client/src/internal/events.dart';
import 'package:livekit_client/src/proto/livekit_models.pb.dart' as lk_models;
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as lk_rtc;
import '../mock/e2e_container.dart';
import '../mock/e2ee_fake_manager.dart';
import '../mock/frame_cryptor_mock.dart';
import '../mock/media_stream_mock.dart';
import '../mock/test_data.dart';
import '../mock/websocket_mock.dart';

/// Timeouts with a short publish timeout so tests that wait it out stay fast.
const _shortPublishTimeouts = Timeouts(
  connection: Duration(seconds: 10),
  debounce: Duration(milliseconds: 20),
  publish: Duration(seconds: 1),
  subscribe: Duration(seconds: 10),
  peerConnection: Duration(seconds: 10),
  iceRestart: Duration(seconds: 10),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late E2EContainer container;
  late Room room;
  late MockWebSocketConnector ws;
  late E2EEManager e2eeManager;
  late FakeFrameCryptorFactory fakeCryptorFactory;

  // Not a `setUp` because one test needs custom connect options.
  Future<void> setUpWith({ConnectOptions connectOptions = const ConnectOptions()}) async {
    Logger.root.level = Level.FINEST;

    container = E2EContainer(connectOptions: connectOptions);
    room = container.room;
    ws = container.wsConnector;
    await container.connectRoom();

    fakeCryptorFactory = FakeFrameCryptorFactory();
    e2eeManager = E2EEManager(BaseKeyProvider(
      TestKeyProvider(),
      rtc.KeyProviderOptions(
        sharedKey: true,
        ratchetSalt: Uint8List(16),
        ratchetWindowSize: 16,
        keyRingSize: 1,
        failureTolerance: -1,
        discardFrameWhenCryptorNotReady: false,
      ),
    ))
      ..cryptorFactory = fakeCryptorFactory
      ..dataCryptorFactory = FakeDataPacketCryptorFactory();
    await e2eeManager.setup(room);
  }

  tearDown(() async {
    await container.dispose();
  });

  lk_models.TrackInfo audioTrackInfo({String? mimeType, lk_models.Encryption_Type? encryption}) => lk_models.TrackInfo(
        sid: remoteAudioTrack.sid,
        type: lk_models.TrackType.AUDIO,
        mimeType: mimeType,
        encryption: encryption,
      );

  /// Delivers a `ParticipantUpdate` for the remote participant carrying
  /// [trackInfo] as its only track.
  void deliverRemoteParticipant(lk_models.TrackInfo trackInfo) {
    final info = lk_models.ParticipantInfo(
      sid: remoteParticipantData.sid,
      identity: remoteParticipantData.identity,
      state: lk_models.ParticipantInfo_State.ACTIVE,
      tracks: [trackInfo],
    );
    ws.onData(lk_rtc.SignalResponse(
      update: lk_rtc.ParticipantUpdate(participants: [info]),
    ).writeToBuffer());
  }

  /// Simulates the media track arriving from the subscriber peer connection
  /// and waits until the SDK reports it subscribed.
  Future<TrackSubscribedEvent> subscribeRemoteTrack() async {
    final stream = FakeMediaStream('${remoteParticipantData.sid}|remote_stream');
    final track = FakeMediaStreamTrack(id: remoteAudioTrack.sid, kind: 'audio');
    container.engine.events.emit(EngineTrackAddedEvent(
      track: track,
      stream: stream,
      receiver: FakeRtpReceiver(),
    ));
    return await room.events.waitFor<TrackSubscribedEvent>(duration: const Duration(seconds: 2));
  }

  Future<void> waitUntil(bool Function() condition,
      {Duration timeout = const Duration(seconds: 3), String? reason}) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    expect(condition(), isTrue, reason: reason);
  }

  group('E2EEManager remote tracks', () {
    test('waits for late track metadata and still creates the frame cryptor', () async {
      await setUpWith();

      // The track is announced before the SFU has its mimeType / encryption.
      deliverRemoteParticipant(audioTrackInfo());
      await room.events.waitFor<ParticipantConnectedEvent>(duration: const Duration(seconds: 1));

      await subscribeRemoteTrack();

      // Metadata still incomplete: no decision should have been made yet.
      expect(fakeCryptorFactory.receiverCryptors, isEmpty);

      // Complete metadata arrives after the subscription.
      deliverRemoteParticipant(audioTrackInfo(
        mimeType: 'audio/opus',
        encryption: lk_models.Encryption_Type.GCM,
      ));

      await waitUntil(
        () =>
            fakeCryptorFactory.receiverCryptors.isNotEmpty &&
            fakeCryptorFactory.receiverCryptors.first.onFrameCryptorStateChanged != null,
        reason: 'frame cryptor should be created once metadata arrives',
      );

      final cryptor = fakeCryptorFactory.receiverCryptors.single;
      expect(cryptor.participantId, remoteParticipantData.identity);
      expect(cryptor.lastEnabled, isTrue);
      expect(cryptor.lastKeyIndex, 0);

      // Cryptor state changes surface as TrackE2EEStateEvent.
      final e2eeStateEvent = room.events.waitFor<TrackE2EEStateEvent>(duration: const Duration(seconds: 1));
      cryptor.onFrameCryptorStateChanged!(remoteAudioTrack.sid, rtc.FrameCryptorState.FrameCryptorStateOk);
      final event = await e2eeStateEvent;
      expect(event.state, E2EEState.kOk);
      expect(event.publication.sid, remoteAudioTrack.sid);
      expect(event.participant.identity, remoteParticipantData.identity);
    });

    test('creates the frame cryptor without codec when mimeType never arrives', () async {
      await setUpWith(connectOptions: const ConnectOptions(timeouts: _shortPublishTimeouts));

      // Encrypted track whose mimeType is never populated. The old handler
      // crashed on `mimeType.split('/')[1]` and never set up the cryptor.
      deliverRemoteParticipant(audioTrackInfo(encryption: lk_models.Encryption_Type.GCM));
      await room.events.waitFor<ParticipantConnectedEvent>(duration: const Duration(seconds: 1));

      await subscribeRemoteTrack();

      // After the publish timeout the cryptor is created anyway.
      await waitUntil(
        () => fakeCryptorFactory.receiverCryptors.isNotEmpty,
        reason: 'frame cryptor should be created for an encrypted track even without a mimeType',
      );
      final cryptor = fakeCryptorFactory.receiverCryptors.single;
      expect(cryptor.participantId, remoteParticipantData.identity);
      expect(cryptor.lastEnabled, isTrue);
    });

    test('skips the frame cryptor promptly for unencrypted tracks', () async {
      await setUpWith();

      // Unencrypted track with complete metadata.
      deliverRemoteParticipant(audioTrackInfo(mimeType: 'audio/opus'));
      await room.events.waitFor<ParticipantConnectedEvent>(duration: const Duration(seconds: 1));

      final skipLogged =
          Logger.root.onRecord.firstWhere((record) => record.message.contains('not setting up frame cryptor'));

      await subscribeRemoteTrack();

      // The decision must be prompt — not delayed until the publish timeout
      // (10s by default) as if the metadata were still missing.
      await skipLogged.timeout(const Duration(seconds: 2));
      expect(fakeCryptorFactory.receiverCryptors, isEmpty);
    });
  });
}
