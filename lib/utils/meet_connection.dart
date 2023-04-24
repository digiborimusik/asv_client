import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:asv_client/core/constants.dart';
import 'package:asv_client/domain/controllers/room_client.dart';

class Transmitter {
  Transmitter({
    required this.clientId,
    required this.roomClient,
    required this.stream,
  }) {
    _init();
  }

  final String clientId;
  final RoomClient roomClient;
  final MediaStream stream;

  RTCPeerConnection? _pc;

  Future _setup() async {
    _pc = await createPeerConnection(peerConfig);

    for (var track in stream.getTracks()) {
      await _pc!.addTrack(track, stream);
    }

    _pc!.onIceCandidate = (candidate) {
      debugPrint('onIceCandidate: $candidate');
      roomClient.sendCandidate(clientId, PcType.tx, candidate);
    };

    _pc!.onConnectionState = (state) {
      debugPrint('onConnectionState tx: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _connect(reconnect: true);
      }
    };
  }

  Future _warmup() async {
    if (_disposed) return;

    roomClient.sendWarmup(clientId);

    try {
      await roomClient.eventStream.firstWhere((event) {
        return event is MeetConnectionReady && event.clientId == clientId;
      }).timeout(const Duration(seconds: 20));
      debugPrint('$clientId is ready for connection ');
    } on TimeoutException {
      debugPrint('Timeout waiting for ready, retrying');
      return await _warmup();
    }
  }

  Future _connect({bool reconnect = false}) async {
    if (_disposed) return;

    if (reconnect) {
      await _pc!.restartIce();
    }

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    roomClient.sendOffer(clientId, offer);

    if (reconnect) return;

    try {
      RoomEvent answer = await roomClient.eventStream.firstWhere((event) {
        return event is MeetConnectionAnswer && event.clientId == clientId;
      }).timeout(const Duration(seconds: 20));

      debugPrint('Received answer from $clientId');

      if (_disposed) return;

      await _pc!.setRemoteDescription((answer as MeetConnectionAnswer).answer);
    } on TimeoutException {
      debugPrint('Timeout waiting for answer, retrying');
      return await _connect(reconnect: reconnect);
    }
  }

  _init() async {
    await _setup();
    await _warmup();
    await _connect();
  }

  addCandidate(RTCIceCandidate candidate) async {
    if (_disposed) return;
    await _pc!.addCandidate(candidate);
  }

  bool _disposed = false;
  void dispose() {
    _disposed = true;
    _pc?.close();
  }
}

class Receiver {
  Receiver({
    required this.clientId,
    required this.roomClient,
    required this.renderer,
  }) {
    _setup();
  }

  final String clientId;
  final RoomClient roomClient;
  final RTCVideoRenderer renderer;

  RTCPeerConnection? _pc;

  Future _setup() async {
    _pc = await createPeerConnection(peerConfig);

    _pc!.onIceCandidate = (candidate) {
      debugPrint('onIceCandidate rx: $candidate');
      roomClient.sendCandidate(clientId, PcType.rx, candidate);
    };

    _pc!.onConnectionState = (state) {
      debugPrint('onConnectionState rx: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        renderer.srcObject = null;
      }
    };

    _pc!.onTrack = (track) async {
      debugPrint('onTrack rx: $track');
      renderer.srcObject = track.streams.first;
    };

    roomClient.sendReady(clientId);
  }

  connect(RTCSessionDescription offer) async {
    await _pc!.setRemoteDescription(offer);
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    roomClient.sendAnswer(clientId, answer);
  }

  addCandidate(RTCIceCandidate candidate) async {
    if (_disposed) return;
    await _pc!.addCandidate(candidate);
  }

  bool _disposed = false;
  void dispose() {
    _disposed = true;
    _pc?.close();
  }
}

class MeetConnection {
  MeetConnection({
    required this.clientId,
    required this.roomClient,
    MediaStream? txStream,
  }) {
    renderer = RTCVideoRenderer();
    renderer.initialize();
    _eventSubscription = roomClient.eventStream.listen(eventHandler);

    // Start transmitting if tx stream provided
    if (txStream != null) initTransmitter(txStream);
  }

  final String clientId;
  final RoomClient roomClient;

  late final StreamSubscription<RoomEvent> _eventSubscription;
  late final RTCVideoRenderer renderer;

  Transmitter? _transmitter;
  Receiver? _receiver;

  set setTxStream(MediaStream? stream) {
    if (stream != null) {
      initTransmitter(stream);
    } else {
      _transmitter?.dispose();
      _transmitter = null;
    }
  }

  initTransmitter(MediaStream stream) {
    _transmitter?.dispose();

    _transmitter = Transmitter(
      clientId: clientId,
      roomClient: roomClient,
      stream: stream,
    );
  }

  initReceiver() {
    _receiver?.dispose();

    _receiver = Receiver(
      clientId: clientId,
      roomClient: roomClient,
      renderer: renderer,
    );
  }

  eventHandler(RoomEvent event) async {
    if (event is MeetConnectionWarmup && event.clientId == clientId) {
      initReceiver();
    }
    if (event is MeetConnectionOffer && event.clientId == clientId) {
      _receiver?.connect(event.offer);
    }

    if (event is MeetConnectionCandidate) {
      if (event.clientId == clientId) {
        // Pay attention to the pcType here
        // RX candidate is for TX pc and vice versa
        if (event.pcType == PcType.tx) {
          if (_receiver != null) {
            debugPrint('RX candidate is received');
            _receiver!.addCandidate(event.candidate);
          } else {
            debugPrint('RX candidate is loss');
          }
        } else {
          if (_transmitter != null) {
            debugPrint('TX candidate is received');
            _transmitter!.addCandidate(event.candidate);
          } else {
            debugPrint('TX candidate is loss');
          }
        }
      }
    }
  }

  dispose() {
    _transmitter?.dispose();
    _receiver?.dispose();
    _eventSubscription.cancel();
    renderer.srcObject = null;
    renderer.dispose();
  }
}
