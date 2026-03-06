import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/server_config.dart';

/// Background server service that runs a WebSocket server on port 8000
/// Handles xiaozhi device connections and AI pipeline processing
class ServerService {
  static const String tag = "ServerService";
  static const int defaultPort = 8000;

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
  final List<List<int>> audioFrames = []; // Store individual Opus frames
  bool isListening = false;
  String? deviceId;

  _ClientSession({required this.webSocket, required this.sessionId});

  void addAudioFrame(List<int> frame) {
    audioFrames.add(List<int>.from(frame));
  }

  void clearAudio() {
    audioFrames.clear();
  }

  int get totalAudioBytes =>
      audioFrames.fold(0, (sum, frame) => sum + frame.length);
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

  // Initialize opus_dart in this isolate
  try {
    initOpus(await opus_flutter.load());
    debugPrint('$tag: Opus initialized successfully');
  } catch (e) {
    debugPrint('$tag: Failed to initialize Opus: $e');
  }

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

  // Opus decoder for converting Opus frames to PCM
  final opusDecoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);

  /// Decode individual Opus frames to PCM samples
  List<int> decodeOpusFramesToPcm(List<List<int>> frames) {
    final List<int> pcmSamples = [];
    int successCount = 0;
    int failCount = 0;

    for (final frame in frames) {
      try {
        final input = Uint8List.fromList(frame);
        final decoded = opusDecoder.decode(input: input);

        // Convert Int16List to bytes (little-endian)
        for (int sample in decoded) {
          pcmSamples.add(sample & 0xFF);
          pcmSamples.add((sample >> 8) & 0xFF);
        }
        successCount++;
      } catch (e) {
        failCount++;
        // Skip failed frames
      }
    }

    debugPrint('$tag: Decoded $successCount frames, failed $failCount');
    return pcmSamples;
  }

  /// Create WAV file header
  Uint8List createWavHeader(int pcmDataLength) {
    const int sampleRate = 16000;
    const int channels = 1;
    const int bitsPerSample = 16;
    final int byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final int blockAlign = channels * bitsPerSample ~/ 8;

    final header = ByteData(44);

    // RIFF header
    header.setUint8(0, 0x52); // 'R'
    header.setUint8(1, 0x49); // 'I'
    header.setUint8(2, 0x46); // 'F'
    header.setUint8(3, 0x46); // 'F'
    header.setUint32(4, 36 + pcmDataLength, Endian.little); // File size - 8
    header.setUint8(8, 0x57); // 'W'
    header.setUint8(9, 0x41); // 'A'
    header.setUint8(10, 0x56); // 'V'
    header.setUint8(11, 0x45); // 'E'

    // fmt chunk
    header.setUint8(12, 0x66); // 'f'
    header.setUint8(13, 0x6D); // 'm'
    header.setUint8(14, 0x74); // 't'
    header.setUint8(15, 0x20); // ' '
    header.setUint32(16, 16, Endian.little); // Chunk size
    header.setUint16(20, 1, Endian.little); // Audio format (PCM)
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);

    // data chunk
    header.setUint8(36, 0x64); // 'd'
    header.setUint8(37, 0x61); // 'a'
    header.setUint8(38, 0x74); // 't'
    header.setUint8(39, 0x61); // 'a'
    header.setUint32(40, pcmDataLength, Endian.little);

    return header.buffer.asUint8List();
  }

  /// Transcribe audio frames using Groq Whisper
  Future<String> transcribeAudioFrames(List<List<int>> frames) async {
    if (config == null || config!.groqApiKey.isEmpty) {
      debugPrint('$tag: No Groq API key configured');
      return '';
    }

    try {
      // Decode Opus frames to PCM
      debugPrint('$tag: Decoding ${frames.length} Opus frames');
      final pcmData = decodeOpusFramesToPcm(frames);

      if (pcmData.isEmpty) {
        debugPrint('$tag: Failed to decode Opus audio');
        return '';
      }

      debugPrint('$tag: Decoded to ${pcmData.length} bytes of PCM');

      // Create WAV file
      final wavHeader = createWavHeader(pcmData.length);
      final wavData = Uint8List(wavHeader.length + pcmData.length);
      wavData.setAll(0, wavHeader);
      wavData.setAll(wavHeader.length, pcmData);

      debugPrint('$tag: Created WAV file: ${wavData.length} bytes');

      final uri = Uri.parse(
        'https://api.groq.com/openai/v1/audio/transcriptions',
      );
      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer ${config!.groqApiKey}';

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          wavData,
          filename: 'audio.wav',
          contentType: MediaType('audio', 'wav'),
        ),
      );

      request.fields['model'] = config!.sttModel;
      request.fields['response_format'] = 'json';
      request.fields['language'] = 'ko'; // Korean

      debugPrint('$tag: Sending ${wavData.length} bytes to Groq STT');

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        // Explicitly decode as UTF-8 to handle Korean text properly
        final responseBody = utf8.decode(response.bodyBytes);
        final json = jsonDecode(responseBody);
        debugPrint('$tag: STT success: ${json['text']}');
        return json['text'] ?? '';
      } else {
        final errorBody = utf8.decode(response.bodyBytes);
        debugPrint('$tag: STT error: ${response.statusCode} - $errorBody');
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
        return results
            .map<String>((m) => m['memory'] as String? ?? '')
            .toList();
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

  // Opus encoder for TTS output
  final opusEncoder = SimpleOpusEncoder(
    sampleRate: 24000, // EdgeTTS outputs 24kHz
    channels: 1,
    application: Application.audio,
  );

  /// Find the end of WebSocket message header (must be declared before use)
  int findHeaderEnd(List<int> data) {
    // Look for \r\n\r\n pattern
    for (int i = 0; i < data.length - 4; i++) {
      if (data[i] == 0x0D &&
          data[i + 1] == 0x0A &&
          data[i + 2] == 0x0D &&
          data[i + 3] == 0x0A) {
        return i + 4;
      }
    }
    // Fallback: skip first 2 bytes (length) + header
    if (data.length > 2) {
      final headerLen = (data[0] << 8) | data[1];
      if (headerLen + 2 < data.length) {
        return headerLen + 2;
      }
    }
    return -1;
  }

  /// Convert PCM to Opus frames and send to client
  void sendPcmAsOpus(_ClientSession session, List<int> pcmData) {
    // 60ms frame at 24kHz = 1440 samples = 2880 bytes (16-bit)
    const int frameSize = 1440;
    const int bytesPerFrame = frameSize * 2;

    int offset = 0;
    int frameCount = 0;
    while (offset + bytesPerFrame <= pcmData.length) {
      // Convert bytes to Int16List
      final frameBytes = pcmData.sublist(offset, offset + bytesPerFrame);
      final Int16List samples = Int16List(frameSize);
      for (int i = 0; i < frameSize; i++) {
        samples[i] = (frameBytes[i * 2]) | (frameBytes[i * 2 + 1] << 8);
      }

      try {
        final encoded = opusEncoder.encode(input: samples);
        sendAudioToClient(session, encoded);
        frameCount++;
      } catch (e) {
        debugPrint('$tag: Opus encode error: $e');
      }

      offset += bytesPerFrame;
    }
    debugPrint('$tag: Sent $frameCount Opus frames');
  }

  /// Convert 44.1kHz WAV from Typecast to 16kHz raw PCM
  Uint8List convertWavTo16kPcm(Uint8List wavBytes) {
    int dataOffset = 44; // Default WAV data offset

    // Safely find the 'data' chunk header
    for (int i = 12; i < wavBytes.length - 4; i++) {
      if (wavBytes[i] == 100 &&
          wavBytes[i + 1] == 97 &&
          wavBytes[i + 2] == 116 &&
          wavBytes[i + 3] == 97) {
        dataOffset = i + 8;
        break;
      }
    }

    ByteData byteData = ByteData.view(wavBytes.buffer, wavBytes.offsetInBytes);
    int numSamples = (wavBytes.length - dataOffset) ~/ 2;

    // Downsample ratio (44100 -> 16000)
    double ratio = 44100 / 16000;
    int outLen = (numSamples / ratio).ceil();

    Uint8List outBytes = Uint8List(outLen * 2);
    ByteData outData = ByteData.view(outBytes.buffer);

    // Fast downsample
    for (int i = 0; i < outLen; i++) {
      int inIndex = (i * ratio).round();
      if (inIndex >= numSamples) inIndex = numSamples - 1;

      int sample = byteData.getInt16(dataOffset + inIndex * 2, Endian.little);
      outData.setInt16(i * 2, sample, Endian.little);
    }
    return outBytes;
  }

  /// Convert text to speech using Typecast
  Future<void> textToSpeechTypecast(
    _ClientSession session,
    String text,
    ServerConfig cfg,
  ) async {
    if (text.isEmpty || cfg.typecastApiKey.isEmpty) {
      debugPrint('$tag: Typecast skipped: Empty text or missing API key.');
      return;
    }

    try {
      // Step 1: Request Speech Synthesis using the OFFICIAL Developer API
      final response = await http.post(
        Uri.parse('https://api.typecast.ai/v1/text-to-speech'),
        headers: {
          'X-API-KEY': cfg.typecastApiKey, // Official Header format
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'text': text,
          'voice_id':
              cfg.ttsVoiceId, // Note: Must start with 'tc_' (e.g., tc_60e5426de...)
          'model':
              'ssfm-v21', // You can change this to 'ssfm-v21' if you prefer
        }),
      );

      // Step 2: Handle the Response
      if (response.statusCode == 200) {
        // Convert the 44.1kHz WAV to 16kHz PCM
        Uint8List pcm16kBytes = convertWavTo16kPcm(response.bodyBytes);

        // REMOVE THE CHUNKING LOOP! Send it all at once.
        sendAudioToClient(session, pcm16kBytes);
        debugPrint(
          '$tag: Sent Typecast audio to client (${pcm16kBytes.length} bytes)',
        );
      } else {
        debugPrint(
          '$tag: Typecast API error: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('$tag: Typecast TTS exception: $e');
    }
  }

  /// Main TTS dispatcher based on provider
  Future<void> textToSpeech(
    _ClientSession session,
    String text,
    ServerConfig cfg,
  ) async {
    if (text.isEmpty) return;

    debugPrint('$tag: TTS provider: ${cfg.ttsProvider}, text: $text');

    switch (cfg.ttsProvider) {
      case 'typecast':
        await textToSpeechTypecast(session, text, cfg);
        break;
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
    String systemPrompt =
        config!.systemPrompt ??
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

      await for (final chunk in streamedResponse.stream.transform(
        utf8.decoder,
      )) {
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
                      'format': 'pcm', // <--- ADD THIS
                      'sample_rate': 16000, // <--- ADD THIS
                    });

                    // 🛑 ADD THIS DELAY!
                    // Gives the client time to init the PCM player before binary arrives
                    await Future.delayed(const Duration(milliseconds: 100));

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
          'format': 'pcm', // <--- ADD THIS
          'sample_rate': 16000, // <--- ADD THIS
        });

        // 🛑 ADD THIS DELAY!
        // Gives the client time to init the PCM player before binary arrives
        await Future.delayed(const Duration(milliseconds: 100));

        await textToSpeech(session, remaining, config!);
      }

      // Send TTS stop message
      sendToClient(session, {'type': 'tts', 'state': 'stop'});
    } catch (e) {
      debugPrint('$tag: LLM exception: $e');
    }
  }

  /// Process audio from client
  Future<void> processClientAudio(_ClientSession session) async {
    if (session.audioFrames.isEmpty) return;

    final frames = List<List<int>>.from(session.audioFrames);
    session.clearAudio();

    debugPrint('$tag: Processing ${frames.length} frames');

    // Transcribe
    final transcript = await transcribeAudioFrames(frames);
    if (transcript.isEmpty) {
      debugPrint('$tag: Empty transcript');
      return;
    }

    debugPrint('$tag: Transcript: $transcript');

    // Send STT result to client
    sendToClient(session, {'type': 'stt', 'text': transcript});

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
    // Handle binary audio data (can be List<int> or Uint8List)
    if (message is List<int>) {
      if (session.isListening) {
        session.addAudioFrame(message);
        debugPrint(
          '$tag: Received frame ${session.audioFrames.length}: ${message.length} bytes',
        );
      } else {
        debugPrint('$tag: Received audio but not listening, ignoring');
      }
      return;
    }

    if (message is! String) {
      debugPrint('$tag: Received unknown message type: ${message.runtimeType}');
      return;
    }

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
          debugPrint('$tag: Listen state: $state');
          if (state == 'start') {
            session.isListening = true;
            session.clearAudio();
            // Don't echo back - device doesn't expect it
            debugPrint('$tag: Started listening, waiting for audio...');
          } else if (state == 'stop') {
            session.isListening = false;
            debugPrint(
              '$tag: Stopped listening, processing ${session.audioFrames.length} frames',
            );
            // Process accumulated audio
            await processClientAudio(session);
          } else if (state == 'detect') {
            // Text input mode
            final text = json['text'] as String?;
            if (text != null && text.isNotEmpty) {
              // Send STT message (echo the text)
              sendToClient(session, {'type': 'stt', 'text': text});

              final memories = await retrieveMemories(text);
              await generateAndSpeak(session, text, memories);
            }
          }
          break;

        case 'abort':
          session.isListening = false;
          session.clearAudio();
          // Don't echo back abort
          debugPrint('$tag: Aborted');
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
  shelf.Handler wsHandler = webSocketHandler((
    WebSocketChannel webSocket,
    String? protocol,
  ) {
    final sessionId = uuid.v4();
    final session = _ClientSession(webSocket: webSocket, sessionId: sessionId);
    sessions[webSocket] = session;

    debugPrint('$tag: New client connected, session: $sessionId');

    // Don't send hello proactively - wait for device to send hello first
    debugPrint('$tag: Client connected, waiting for hello...');

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
        final path = request.url.path;

        // Handle WebSocket connections at /xiaozhi/v1/ or root
        if (request.headers['upgrade']?.toLowerCase() == 'websocket') {
          if (path == '' ||
              path == '/' ||
              path == 'xiaozhi/v1/' ||
              path == 'xiaozhi/v1') {
            return await wsHandler(request);
          }
        }

        // Status endpoint
        if (path == '' || path == '/') {
          return shelf.Response.ok(
            jsonEncode({
              'status': 'running',
              'service': 'Xiaozhi AI Server',
              'websocket': 'ws://IP:${ServerService.defaultPort}/xiaozhi/v1/',
              'port': ServerService.defaultPort,
              'clients': sessions.length,
              'configured': config != null,
              'timestamp': DateTime.now().toIso8601String(),
            }),
            headers: {'content-type': 'application/json'},
          );
        }

        // Health check
        if (path == 'health' || path == 'xiaozhi/health') {
          return shelf.Response.ok(
            jsonEncode({'status': 'healthy'}),
            headers: {'content-type': 'application/json'},
          );
        }

        // OTA endpoint - returns server configuration to xiaozhi devices
        if (path == 'xiaozhi/ota/' || path == 'xiaozhi/ota') {
          // Get local IP address for WebSocket URL
          String localIp = '0.0.0.0';
          try {
            final interfaces = await NetworkInterface.list(
              type: InternetAddressType.IPv4,
              includeLinkLocal: false,
            );
            for (final interface in interfaces) {
              for (final addr in interface.addresses) {
                if (!addr.isLoopback && addr.address.startsWith('192.168')) {
                  localIp = addr.address;
                  break;
                }
              }
              if (localIp != '0.0.0.0') break;
            }
            // Fallback to first non-loopback
            if (localIp == '0.0.0.0') {
              for (final interface in interfaces) {
                for (final addr in interface.addresses) {
                  if (!addr.isLoopback) {
                    localIp = addr.address;
                    break;
                  }
                }
                if (localIp != '0.0.0.0') break;
              }
            }
          } catch (e) {
            debugPrint('$tag: Error getting local IP: $e');
          }

          final now = DateTime.now();
          final response = {
            'server_time': {
              'timestamp': now.millisecondsSinceEpoch,
              'timezone_offset': now.timeZoneOffset.inMinutes,
            },
            'firmware': {'version': '1.0.0', 'url': ''},
            'websocket': {
              'url': 'ws://$localIp:${ServerService.defaultPort}/xiaozhi/v1/',
              'token': 'test-token',
            },
          };

          debugPrint(
            '$tag: OTA request - returning websocket: ws://$localIp:${ServerService.defaultPort}/xiaozhi/v1/',
          );

          return shelf.Response.ok(
            jsonEncode(response),
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

    debugPrint(
      '$tag: Server running on ws://${httpServer.address.address}:${httpServer.port}',
    );

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
