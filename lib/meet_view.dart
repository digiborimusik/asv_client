import 'dart:async';
import 'package:asv_client/core/constants.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:asv_client/domain/controllers/room_client.dart';
import 'package:asv_client/utils/first_where_or_null.dart';

class MeetConnection {
  MeetConnection({
    required this.clientId,
    required this.roomClient,
    this.localstream,
  }) {
    renderer = RTCVideoRenderer();
    renderer.initialize();
    _eventSubscription = roomClient.eventStream.listen(eventHandler);
    init();
  }
  final String clientId;
  // final bool master;
  final RoomClient roomClient;
  MediaStream? localstream;

  RTCPeerConnection? _txPc;
  RTCPeerConnection? _rxPc;

  late final RTCVideoRenderer renderer;
  late final StreamSubscription<RoomEvent> _eventSubscription;

  init() async {
    if (localstream != null) initTx();
  }

  setStream(MediaStream? stream) {
    if (stream != null) {
      localstream = stream;
      _txPc?.close();
      _txPc = null;
      initTx();
    } else {
      _txPc!.removeStream(localstream!);
      // _txPc?.close();
      // _txPc = null;
      // localstream = null;
    }
  }

  initTx() async {
    _txPc = await createPeerConnection(peerConfig);

    // _txPc!.onIceCandidate = (candidate) {
    //   debugPrint('onIceCandidate tx: $candidate');
    //   roomClient.sendCandidate(clientId, PcType.tx, candidate);
    // };

    _txPc!.onConnectionState = (state) {
      debugPrint('onConnectionState tx: $state');
    };

    _txPc!.addStream(localstream!);

    final offer = await _txPc!.createOffer();
    await _txPc!.setLocalDescription(offer);

    roomClient.sendOffer(clientId, offer);

    await roomClient.eventStream.firstWhere((event) => event is MeetConnectionAnswer && event.clientId == clientId).timeout(const Duration(seconds: 1),
        onTimeout: () {
      // Check if the pc is not null because it could be disposed
      if (_txPc != null) {
        // Close the pc and try again
        _txPc!.close();
        _txPc = null;
        initTx();
      }
      debugPrint('Timeout waiting for answer');
      throw TimeoutException('Timeout waiting for answer');
    }).then((answer) {
      debugPrint('Received answer');
      // Check if the pc is not null because it could be disposed
      if (_txPc != null) {
        _txPc!.setRemoteDescription((answer as MeetConnectionAnswer).answer);
      }
    }).onError((error, stackTrace) => null);
  }

  initRx(RTCSessionDescription offer) async {
    _rxPc?.close();
    _rxPc = await createPeerConnection(peerConfig);

    _rxPc!.onIceCandidate = (candidate) {
      debugPrint('onIceCandidate rx: $candidate');
      roomClient.sendCandidate(clientId, PcType.rx, candidate);
    };

    _rxPc!.onConnectionState = (state) {
      debugPrint('onConnectionState rx: $state');
    };

    _rxPc!.onAddStream = (stream) {
      debugPrint('onAddStream rx: $stream');
      renderer.srcObject = stream;
    };

    _rxPc!.onRemoveStream = (stream) {
      debugPrint('onRemoveStream rx: $stream');
      renderer.srcObject = null;
    };

    _rxPc!.setRemoteDescription(offer);
    final answer = await _rxPc!.createAnswer();
    await _rxPc!.setLocalDescription(answer);
    roomClient.sendAnswer(clientId, answer);
  }

  eventHandler(RoomEvent event) {
    if (event is MeetConnectionOffer && event.clientId == clientId) {
      initRx(event.offer);
    }

    if (event is MeetConnectionCandidate) {
      if (event.clientId == clientId) {
        // Pay attention to the pcType here
        // RX candidate is for TX pc and vice versa
        if (event.pcType == PcType.tx) {
          if (_rxPc != null) {
            _rxPc!.addCandidate(event.candidate);
          }
        } else {
          if (_txPc != null) {
            _txPc!.addCandidate(event.candidate);
          }
        }
      }
    }
  }

  dispose() {
    _rxPc?.close();
    _rxPc = null;
    _txPc?.close();
    _txPc = null;
    renderer.srcObject = null;
    renderer.dispose();
    _eventSubscription.cancel();
  }
}

class MeetView extends StatefulWidget {
  const MeetView({super.key, required this.roomClient});

  final RoomClient roomClient;

  @override
  State<MeetView> createState() => _MeetViewState();
}

class _MeetViewState extends State<MeetView> {
  late final StreamSubscription<RoomEvent> eventSubscription;
  MediaStream? localStream;
  final localRenderer = RTCVideoRenderer();
  // List<MediaDeviceInfo>? _mediaDevicesList;
  List<MeetConnection> connections = [];

  @override
  void initState() {
    super.initState();
    localRenderer.initialize();
    eventSubscription = widget.roomClient.eventStream.listen((event) async {
      if (event is ClientJoin) {
        MeetConnection? connection = connections.firstWhereOrNull((connection) => connection.clientId == event.clientId);
        if (connection != null) return;
        connections.add(MeetConnection(
          clientId: event.clientId,
          roomClient: widget.roomClient,
          localstream: localStream,
        ));
      }

      if (event is ClientSignal) {
        MeetConnection? connection = connections.firstWhereOrNull((connection) => connection.clientId == event.clientId);
        if (connection != null) return;
        connections.add(MeetConnection(
          clientId: event.clientId,
          roomClient: widget.roomClient,
          localstream: localStream,
        ));
      }

      if (event is ClientLeave) {
        MeetConnection? connection = connections.firstWhereOrNull((connection) => connection.clientId == event.clientId);
        connection?.dispose();
        connections.remove(connection);
      }

      setState(() {});
    });

    Timer.periodic(Duration(seconds: 1), (timer) {
      if (mounted) setState(() {});
      print('tick');
    });
  }

  Future streamCamera() async {
    stopStream();
    final stream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': true});
    // setState(() {
    localStream = stream;
    // });
    localRenderer.srcObject = stream;
    for (var connection in connections) {
      connection.setStream(stream);
    }
  }

  Future streamDisplay() async {
    stopStream();
    final stream = await navigator.mediaDevices.getDisplayMedia({'audio': true, 'video': true});

    // setState(() {
    localStream = stream;
    // });
    localRenderer.srcObject = stream;
    for (var connection in connections) {
      connection.setStream(stream);
    }
  }

  stopStream() async {
    for (var connection in connections) {
      connection.setStream(null);
    }
    if (kIsWeb) {
      localStream?.getTracks().forEach((track) => track.stop());
    }
    localRenderer.srcObject = null;
    localStream?.dispose();
  }

  @override
  void deactivate() {
    super.deactivate();
    stopStream();
    eventSubscription.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextButton(
          onPressed: streamCamera,
          child: const Text('Start camera'),
        ),
        TextButton(
          onPressed: streamDisplay,
          child: const Text('Start display'),
        ),
        TextButton(
          onPressed: stopStream,
          child: const Text('Stop stream'),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Container(
                  color: Colors.amber,
                  width: 100,
                  height: 100,
                  child: RTCVideoView(
                    localRenderer,
                    mirror: true,
                  ),
                ),
                ...connections
                    .map(
                      (connection) => Container(
                        color: Colors.blue,
                        width: 100,
                        height: 100,
                        child: RTCVideoView(connection.renderer),
                      ),
                    )
                    .toList()
              ],
            ),
          ),
        ),
      ],
    );
  }
}
