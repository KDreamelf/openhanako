import 'dart:async';
import 'dart:io';

import 'p2p_message.dart';

typedef P2pMessageHandler =
    void Function(P2pEnvelope envelope, InternetAddress sender, int senderPort);

class P2pTransport {
  P2pTransport({this.bindPort = 0});

  final int bindPort;
  RawDatagramSocket? _socket;
  P2pMessageHandler? onMessage;
  String? _advertisedHost;

  InternetAddress? get localAddress => _socket?.address;
  int? get localPort => _socket?.port;
  String? get advertisedHost => _advertisedHost;

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, bindPort);
    _advertisedHost = await _detectAdvertisedHost();
    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket!.receive();
      if (datagram == null) return;
      final envelope = P2pEnvelope.decode(datagram.data);
      if (envelope == null) return;
      onMessage?.call(envelope, datagram.address, datagram.port);
    });
  }

  void send(P2pEnvelope envelope, InternetAddress address, int port) {
    final data = envelope.encode();
    _socket?.send(data, address, port);
  }

  void sendTo(P2pEnvelope envelope, String host, int port) {
    final data = envelope.encode();
    try {
      final addr = InternetAddress(host);
      _socket?.send(data, addr, port);
    } catch (_) {}
  }

  Future<Duration?> probe(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final probeId = DateTime.now().microsecondsSinceEpoch.toString();
    final envelope = P2pEnvelope(
      type: P2pMessageType.probe,
      payload: {
        'probeId': probeId,
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
    final start = DateTime.now();
    final completer = Completer<Duration?>();
    void listener(P2pEnvelope env, InternetAddress address, int port) {
      if (env.type == P2pMessageType.probeAck &&
          env.payload['probeId'] == probeId) {
        if (!completer.isCompleted) {
          completer.complete(DateTime.now().difference(start));
        }
      }
    }

    final prevHandler = onMessage;
    onMessage = (env, addr, port) {
      listener(env, addr, port);
      prevHandler?.call(env, addr, port);
    };
    sendTo(envelope, host, port);
    try {
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      onMessage = prevHandler;
    }
  }

  Future<void> stop() async {
    _socket?.close();
    _socket = null;
    _advertisedHost = null;
  }

  Future<String?> _detectAdvertisedHost() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback && !address.isMulticast) {
            return address.address;
          }
        }
      }
    } catch (_) {}
    final address = _socket?.address.address;
    if (address == null || address == '0.0.0.0') return null;
    return address;
  }
}
