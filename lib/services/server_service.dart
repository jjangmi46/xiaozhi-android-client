import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/server_config.dart';

/// Background server service that runs a WebSocket server on port 8080
/// Handles xiaozhi device connections and AI pipeline processing
class ServerService {
  static const String tag = "ServerService";
  static const int defaultPort = 8080;

  static final ServerService _instance = ServerService._internal();
  factory ServerService() => _instance;
  ServerService._internal();

  final FlutterBackgroundService _service = FlutterBackgroundService();
  bool _isInitialized = false;
  ServerConfig? _config;

  /// Initialize the background service
  Future<void> initialize() async {
    if (_isInitialized) return;

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'xiaozhi_server_channel',
        initialNotificationTitle: 'Xiaozhi Server',
        initialNotificationContent: 'WebSocket server is running',
        foregroundServiceNotificationId: 888,
        foregroundServiceTypes: [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onStart,
        onBackground: _onIosBackground,
      ),
    );

    _isInitialized = true;
    debugPrint('$tag: Background service initialized');
  }

  /// Start the background service with config
  Future<void> start(ServerConfig config) async {
    _config = config;

    if (!_isInitialized) {
      await initialize();
    }

    await _service.startService();

    // Send config to the background isolate
    await Future.delayed(const Duration(milliseconds: 500));
    _service.invoke('config', config.toJson());

    debugPrint('$tag: Background service started with config');
  }

  /// Stop the background service
  Future<void> stop() async {
    _service.invoke('stop');
    debugPrint('$tag: Background service stopped');
  }

  /// Check if service is running
  Future<bool> isRunning() async {
    return await _service.isRunning();
  }

  /// Update config
  void updateConfig(ServerConfig config) {
    _config = config;
    _service.invoke('config', config.toJson());
  }

  /// Listen for events from the background service
  Stream<Map<String, dynamic>?> get onEvent {
    return _service.on('event');
  }
}

// iOS background handler
@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}

/// Client session for tracking connected xiaozhi devices
class _ClientSession {
  final WebSocketChannel webSocket;
  final String sessionId;
  final List<int> audioBuffer = [];
  bool isListening = false;
  String? deviceId;

  _ClientSession({required this.webSocket, required this.sessionId});
}

// Main service entry point - runs in a separate isolate
@pragma('vm:entry-point')
void _onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();

  const String tag = "ServerService";
  HttpServer? httpServer;
  final Map<WebSocketChannel, _ClientSession> sessions = {};
  ServerConfig? config;
  final uuid = const Uuid();

  debugPrint('$tag: Service isolate started');

  // Handle config updates
  service.on('config').listen((event) {
    if (event != null) {
      config = ServerConfig.fromJson(Map<String, dynamic>.from(event));
      debugPrint('$tag: Config updated');
    }
  });

  // Handle stop command
  service.on('stop').listen((event) async {
    debugPrint('$tag: Received stop command');
    await httpServer?.close(force: true);
    for (var session in sessions.values) {
      await session.webSocket.sink.close();
    }
    sessions.clear();
    await service.stopSelf();
  });

  /// Send message to a specific client
  void sendToClient(_ClientSession session, Map<String, dynamic> message) {
    try {
      session.webSocket.sink.add(jsonEncode(message));
    } catch (e) {
      debugPrint('$tag: Error sending to client: $e');
    }
  }

  /// Send binary audio to client
  void sendAudioToClient(_ClientSession session, List<int> audioData) {
    try {
      session.webSocket.sink.add(audioData);
    } catch (e) {
      debugPrint('$tag: Error sending audio to client: $e');
    }
  }

  /// Transcribe audio using Groq Whisper
  Future<String> transcribeAudio(List<int> audioData) async {
    if (config == null || config!.groqApiKey.isEmpty) {
      debugPrint('$tag: No Groq API key configured');
      return '';
    }

    try {
      final uri = Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions');
      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer ${config!.groqApiKey}';

      request.files.add(http.MultipartFile.fromBytes(
        'file',
        audioData,
        filename: 'audio.opus',
        contentType: MediaType('audio', 'opus'),
      ));

      request.fields['model'] = config!.sttModel;
      request.fields['response_format'] = 'json';

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        return json['text'] ?? '';
      } else {
        debugPrint('$tag: STT error: ${response.statusCode}');
        return '';
      }
    } catch (e) {
      debugPrint('$tag: STT exception: $e');
      return '';
    }
  }

  /// Retrieve memories from mem0
  Future<List<String>> retrieveMemories(String query) async {
    if (config == null || config!.mem0ApiKey.isEmpty) return [];

    try {
      final response = await http.post(
        Uri.parse('https://api.mem0.ai/v1/memories/search/'),
        headers: {
          'Authorization': 'Token ${config!.mem0ApiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'query': query,
          'user_id': config!.mem0UserId ?? 'default_user',
          'limit': 5,
        }),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final results = json['results'] as List? ?? [];
        return results.map<String>((m) => m['memory'] as String? ?? '').toList();
      }
    } catch (e) {
      debugPrint('$tag: mem0 exception: $e');
    }
    return [];
  }

  /// Check for sentence completion
  bool isSentenceComplete(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final lastChar = trimmed[trimmed.length - 1];
    return '.!?。！？'.contains(lastChar);
  }

  /// Convert text to speech using Typecast
  Future<void> textToSpeech(
    _ClientSession session,
    String text,
    ServerConfig cfg,
  ) async {
    if (text.isEmpty || cfg.typecastApiKey.isEmpty) return;

    try {
      final response = await http.post(
        Uri.parse('https://typecast.ai/api/speak'),
        headers: {
          'Authorization': 'Bearer ${cfg.typecastApiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'text': text,
          'voice_id': cfg.ttsVoiceId,
          'format': 'opus',
          'sample_rate': 16000,
        }),
      );

      if (response.statusCode == 200) {
        final contentType = response.headers['content-type'] ?? '';

        if (contentType.contains('audio')) {
          sendAudioToClient(session, response.bodyBytes);
        } else {
          // JSON with audio URL
          final json = jsonDecode(response.body);
          final audioUrl = json['audio_url'] ?? json['url'];
          if (audioUrl != null) {
            final audioResponse = await http.get(Uri.parse(audioUrl));
            if (audioResponse.statusCode == 200) {
              sendAudioToClient(session, audioResponse.bodyBytes);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('$tag: TTS exception: $e');
    }
  }

  /// Generate LLM response and stream TTS
  Future<void> generateAndSpeak(
    _ClientSession session,
    String userMessage,
    List<String> memories,
  ) async {
    if (config == null) return;

    // Build system prompt
    String systemPrompt = config!.systemPrompt ??
        'You are a helpful AI assistant. Respond naturally and concisely in Korean.';

    if (memories.isNotEmpty) {
      systemPrompt += '\n\nRelevant context:\n';
      for (final memory in memories) {
        systemPrompt += '- $memory\n';
      }
    }

    try {
      // Call Groq LLM with streaming
      final request = http.Request(
        'POST',
        Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
      );
      request.headers['Authorization'] = 'Bearer ${config!.groqApiKey}';
      request.headers['Content-Type'] = 'application/json';

      request.body = jsonEncode({
        'model': config!.llmModel,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userMessage},
        ],
        'stream': true,
        'max_tokens': 1024,
        'temperature': 0.7,
      });

      final streamedResponse = await http.Client().send(request);

      final StringBuffer sentenceBuffer = StringBuffer();
      final StringBuffer fullResponse = StringBuffer();

      await for (final chunk in streamedResponse.stream.transform(utf8.decoder)) {
        for (final line in chunk.split('\n')) {
          if (line.startsWith('data: ')) {
            final data = line.substring(6);
            if (data == '[DONE]') continue;

            try {
              final json = jsonDecode(data);
              final delta = json['choices']?[0]?['delta']?['content'];
              if (delta != null) {
                fullResponse.write(delta);
                sentenceBuffer.write(delta);

                final sentence = sentenceBuffer.toString();
                if (isSentenceComplete(sentence)) {
                  final completeSentence = sentence.trim();
                  if (completeSentence.isNotEmpty) {
                    // Send TTS sentence_start message
                    sendToClient(session, {
                      'type': 'tts',
                      'state': 'sentence_start',
                      'text': completeSentence,
                    });

                    // Convert to speech and send audio
                    await textToSpeech(session, completeSentence, config!);
                  }
                  sentenceBuffer.clear();
                }
              }
            } catch (e) {
              // Skip malformed JSON
            }
          }
        }
      }

      // Process remaining text
      final remaining = sentenceBuffer.toString().trim();
      if (remaining.isNotEmpty) {
        sendToClient(session, {
          'type': 'tts',
          'state': 'sentence_start',
          'text': remaining,
        });
        await textToSpeech(session, remaining, config!);
      }

      // Send TTS stop message
      sendToClient(session, {
        'type': 'tts',
        'state': 'stop',
      });

    } catch (e) {
      debugPrint('$tag: LLM exception: $e');
    }
  }

  /// Process audio from client
  Future<void> processClientAudio(_ClientSession session) async {
    if (session.audioBuffer.isEmpty) return;

    final audioData = List<int>.from(session.audioBuffer);
    session.audioBuffer.clear();

    debugPrint('$tag: Processing ${audioData.length} bytes of audio');

    // Transcribe
    final transcript = await transcribeAudio(audioData);
    if (transcript.isEmpty) {
      debugPrint('$tag: Empty transcript');
      return;
    }

    debugPrint('$tag: Transcript: $transcript');

    // Send STT result to client
    sendToClient(session, {
      'type': 'stt',
      'text': transcript,
    });

    // Emit event to main isolate
    service.invoke('event', {
      'type': 'transcript',
      'sessionId': session.sessionId,
      'text': transcript,
    });

    // Retrieve memories
    final memories = await retrieveMemories(transcript);

    // Generate response and speak
    await generateAndSpeak(session, transcript, memories);
  }

  /// Handle incoming xiaozhi protocol messages
  void handleMessage(_ClientSession session, dynamic message) async {
    if (message is List<int>) {
      // Binary audio data
      if (session.isListening) {
        session.audioBuffer.addAll(message);
      }
      return;
    }

    if (message is! String) return;

    try {
      final json = jsonDecode(message);
      final type = json['type'] as String?;

      debugPrint('$tag: Received message type: $type');

      switch (type) {
        case 'hello':
          // Respond to hello
          session.deviceId = json['device_id'];
          sendToClient(session, {
            'type': 'hello',
            'session_id': session.sessionId,
            'version': 1,
            'transport': 'websocket',
            'audio_params': {
              'format': 'opus',
              'sample_rate': 16000,
              'channels': 1,
              'frame_duration': 60,
            },
          });
          break;

        case 'listen':
          final state = json['state'] as String?;
          if (state == 'start') {
            session.isListening = true;
            session.audioBuffer.clear();
            sendToClient(session, {
              'type': 'listen',
              'state': 'start',
              'session_id': session.sessionId,
            });
          } else if (state == 'stop') {
            session.isListening = false;
            sendToClient(session, {
              'type': 'listen',
              'state': 'stop',
              'session_id': session.sessionId,
            });
            // Process accumulated audio
            await processClientAudio(session);
          } else if (state == 'detect') {
            // Text input mode
            final text = json['text'] as String?;
            if (text != null && text.isNotEmpty) {
              // Send STT message (echo the text)
              sendToClient(session, {
                'type': 'stt',
                'text': text,
              });

              final memories = await retrieveMemories(text);
              await generateAndSpeak(session, text, memories);
            }
          }
          break;

        case 'abort':
          session.isListening = false;
          session.audioBuffer.clear();
          sendToClient(session, {
            'type': 'abort',
            'session_id': session.sessionId,
          });
          break;

        case 'speak':
          // Handle speak command - acknowledge and prepare for TTS
          sendToClient(session, {
            'type': 'start',
            'session_id': session.sessionId,
          });
          break;
      }
    } catch (e) {
      debugPrint('$tag: Error handling message: $e');
    }
  }

  // Create WebSocket handler
  shelf.Handler wsHandler = webSocketHandler((WebSocketChannel webSocket, String? protocol) {
    final sessionId = uuid.v4();
    final session = _ClientSession(webSocket: webSocket, sessionId: sessionId);
    sessions[webSocket] = session;

    debugPrint('$tag: New client connected, session: $sessionId');

    // Send initial hello
    sendToClient(session, {
      'type': 'hello',
      'session_id': sessionId,
      'version': 1,
      'transport': 'websocket',
      'audio_params': {
        'format': 'opus',
        'sample_rate': 16000,
        'channels': 1,
        'frame_duration': 60,
      },
    });

    webSocket.stream.listen(
      (message) => handleMessage(session, message),
      onDone: () {
        debugPrint('$tag: Client disconnected: $sessionId');
        sessions.remove(webSocket);
      },
      onError: (error) {
        debugPrint('$tag: Client error: $error');
        sessions.remove(webSocket);
      },
    );
  });

  // Create HTTP handler
  var handler = const shelf.Pipeline()
      .addMiddleware(shelf.logRequests())
      .addMiddleware(_corsMiddleware())
      .addHandler((shelf.Request request) async {
        if (request.headers['upgrade']?.toLowerCase() == 'websocket') {
          return await wsHandler(request);
        }

        if (request.url.path == '' || request.url.path == '/') {
          return shelf.Response.ok(
            jsonEncode({
              'status': 'running',
              'service': 'Xiaozhi AI Server',
              'port': ServerService.defaultPort,
              'clients': sessions.length,
              'configured': config != null,
              'timestamp': DateTime.now().toIso8601String(),
            }),
            headers: {'content-type': 'application/json'},
          );
        }

        return shelf.Response.notFound('Not found');
      });

  // Start server
  try {
    httpServer = await shelf_io.serve(
      handler,
      InternetAddress.anyIPv4,
      ServerService.defaultPort,
    );

    debugPrint('$tag: Server running on ws://${httpServer.address.address}:${httpServer.port}');

    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'Xiaozhi AI Server',
        content: 'Running on port ${ServerService.defaultPort}',
      );
    }
  } catch (e) {
    debugPrint('$tag: Failed to start server: $e');

    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'Server Error',
        content: 'Failed: $e',
      );
    }
  }
}

shelf.Middleware _corsMiddleware() {
  return (shelf.Handler handler) {
    return (shelf.Request request) async {
      if (request.method == 'OPTIONS') {
        return shelf.Response.ok('', headers: _corsHeaders);
      }
      final response = await handler(request);
      return response.change(headers: _corsHeaders);
    };
  };
}

const _corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
};
