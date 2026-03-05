import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/server_config.dart';

/// Callback for streaming audio chunks back to the device
typedef AudioChunkCallback = void Function(Uint8List audioData);

/// Callback for streaming text (for display/logging)
typedef TextCallback = void Function(String text, {bool isUser});

/// AI Pipeline that orchestrates STT -> Memory -> LLM -> TTS
class AIPipeline {
  static const String TAG = "AIPipeline";

  final ServerConfig config;
  final AudioChunkCallback onAudioChunk;
  final TextCallback? onText;

  // Conversation history for context
  final List<Map<String, String>> _conversationHistory = [];

  // Audio buffer for accumulating opus frames
  final List<int> _audioBuffer = [];
  bool _isProcessing = false;

  AIPipeline({
    required this.config,
    required this.onAudioChunk,
    this.onText,
  });

  /// Process incoming audio data from the device
  /// Accumulates audio frames until processing is triggered
  void addAudioData(List<int> opusData) {
    _audioBuffer.addAll(opusData);
  }

  /// Process the accumulated audio buffer
  /// Called when the device signals end of speech (listen state: stop)
  Future<void> processAudio() async {
    if (_isProcessing || _audioBuffer.isEmpty) return;

    _isProcessing = true;

    try {
      // Copy and clear buffer
      final audioData = Uint8List.fromList(_audioBuffer);
      _audioBuffer.clear();

      debugPrint('$TAG: Processing ${audioData.length} bytes of audio');

      // Step 1: STT - Transcribe audio to text
      final transcript = await _transcribeAudio(audioData);
      if (transcript.isEmpty) {
        debugPrint('$TAG: Empty transcript, skipping');
        return;
      }

      debugPrint('$TAG: Transcript: $transcript');
      onText?.call(transcript, isUser: true);

      // Step 2: Retrieve memories from mem0
      final memories = await _retrieveMemories(transcript);

      // Step 3: Generate LLM response with streaming
      await _generateResponse(transcript, memories);

      // Step 4: Store the interaction in mem0
      await _storeMemory(transcript);

    } catch (e) {
      debugPrint('$TAG: Error processing audio: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// Process text input directly (for text-based interactions)
  Future<void> processText(String text) async {
    if (_isProcessing || text.isEmpty) return;

    _isProcessing = true;

    try {
      debugPrint('$TAG: Processing text: $text');
      onText?.call(text, isUser: true);

      // Step 1: Retrieve memories
      final memories = await _retrieveMemories(text);

      // Step 2: Generate response
      await _generateResponse(text, memories);

      // Step 3: Store memory
      await _storeMemory(text);

    } catch (e) {
      debugPrint('$TAG: Error processing text: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// Transcribe audio using Groq Whisper API
  Future<String> _transcribeAudio(Uint8List audioData) async {
    try {
      final uri = Uri.parse('https://api.groq.com/openai/v1/audio/transcriptions');

      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer ${config.groqApiKey}';

      // Add the audio file
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        audioData,
        filename: 'audio.opus',
        contentType: MediaType('audio', 'opus'),
      ));

      request.fields['model'] = config.sttModel;
      request.fields['language'] = 'ko'; // Korean, adjust as needed
      request.fields['response_format'] = 'json';

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        return json['text'] ?? '';
      } else {
        debugPrint('$TAG: STT error: ${response.statusCode} - ${response.body}');
        return '';
      }
    } catch (e) {
      debugPrint('$TAG: STT exception: $e');
      return '';
    }
  }

  /// Retrieve relevant memories from mem0
  Future<List<String>> _retrieveMemories(String query) async {
    if (config.mem0ApiKey.isEmpty) return [];

    try {
      final uri = Uri.parse('https://api.mem0.ai/v1/memories/search/');

      final response = await http.post(
        uri,
        headers: {
          'Authorization': 'Token ${config.mem0ApiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'query': query,
          'user_id': config.mem0UserId ?? 'default_user',
          'limit': 5,
        }),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final results = json['results'] as List? ?? [];
        return results.map<String>((m) => m['memory'] as String? ?? '').toList();
      } else {
        debugPrint('$TAG: mem0 search error: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      debugPrint('$TAG: mem0 exception: $e');
      return [];
    }
  }

  /// Store interaction in mem0
  Future<void> _storeMemory(String userMessage) async {
    if (config.mem0ApiKey.isEmpty) return;

    try {
      final uri = Uri.parse('https://api.mem0.ai/v1/memories/');

      // Get recent conversation for context
      final recentMessages = _conversationHistory.take(4).toList();

      await http.post(
        uri,
        headers: {
          'Authorization': 'Token ${config.mem0ApiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'messages': recentMessages,
          'user_id': config.mem0UserId ?? 'default_user',
        }),
      );
    } catch (e) {
      debugPrint('$TAG: mem0 store exception: $e');
    }
  }

  /// Generate LLM response using Groq with streaming
  Future<void> _generateResponse(String userMessage, List<String> memories) async {
    // Build messages for LLM
    final messages = <Map<String, String>>[];

    // System prompt with memories
    String systemPrompt = config.systemPrompt ??
        'You are a helpful AI assistant. Respond naturally and concisely.';

    if (memories.isNotEmpty) {
      systemPrompt += '\n\nRelevant context from previous conversations:\n';
      for (final memory in memories) {
        systemPrompt += '- $memory\n';
      }
    }

    messages.add({'role': 'system', 'content': systemPrompt});

    // Add conversation history
    messages.addAll(_conversationHistory);

    // Add current user message
    messages.add({'role': 'user', 'content': userMessage});
    _conversationHistory.add({'role': 'user', 'content': userMessage});

    try {
      final uri = Uri.parse('https://api.groq.com/openai/v1/chat/completions');

      final request = http.Request('POST', uri);
      request.headers['Authorization'] = 'Bearer ${config.groqApiKey}';
      request.headers['Content-Type'] = 'application/json';

      request.body = jsonEncode({
        'model': config.llmModel,
        'messages': messages,
        'stream': true,
        'max_tokens': 1024,
        'temperature': 0.7,
      });

      final streamedResponse = await http.Client().send(request);

      // Process streaming response
      final StringBuffer fullResponse = StringBuffer();
      final StringBuffer sentenceBuffer = StringBuffer();

      await for (final chunk in streamedResponse.stream.transform(utf8.decoder)) {
        // Parse SSE format
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

                // Check for sentence boundaries
                final sentence = sentenceBuffer.toString();
                if (_isSentenceComplete(sentence)) {
                  final completeSentence = sentence.trim();
                  if (completeSentence.isNotEmpty) {
                    onText?.call(completeSentence, isUser: false);

                    // Convert sentence to TTS and send audio
                    await _textToSpeech(completeSentence);
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

      // Process any remaining text
      final remaining = sentenceBuffer.toString().trim();
      if (remaining.isNotEmpty) {
        onText?.call(remaining, isUser: false);
        await _textToSpeech(remaining);
      }

      // Store assistant response in history
      final assistantResponse = fullResponse.toString();
      _conversationHistory.add({'role': 'assistant', 'content': assistantResponse});

      // Keep history manageable
      while (_conversationHistory.length > 20) {
        _conversationHistory.removeAt(0);
      }

    } catch (e) {
      debugPrint('$TAG: LLM exception: $e');
    }
  }

  /// Check if text contains a complete sentence
  bool _isSentenceComplete(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;

    // Check for sentence-ending punctuation
    final lastChar = trimmed[trimmed.length - 1];
    return '.!?。！？'.contains(lastChar);
  }

  /// Convert text to speech using Typecast API
  Future<void> _textToSpeech(String text) async {
    if (text.isEmpty || config.typecastApiKey.isEmpty) return;

    try {
      // Typecast API endpoint
      final uri = Uri.parse('https://typecast.ai/api/speak');

      final response = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer ${config.typecastApiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'text': text,
          'voice_id': config.ttsVoiceId,
          'format': 'opus', // Request opus format for xiaozhi compatibility
          'sample_rate': 16000,
        }),
      );

      if (response.statusCode == 200) {
        // Check if response is audio data or JSON with URL
        final contentType = response.headers['content-type'] ?? '';

        if (contentType.contains('audio')) {
          // Direct audio response
          onAudioChunk(response.bodyBytes);
        } else {
          // JSON response with audio URL
          final json = jsonDecode(response.body);
          final audioUrl = json['audio_url'] ?? json['url'];

          if (audioUrl != null) {
            final audioResponse = await http.get(Uri.parse(audioUrl));
            if (audioResponse.statusCode == 200) {
              onAudioChunk(audioResponse.bodyBytes);
            }
          }
        }
      } else {
        debugPrint('$TAG: TTS error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('$TAG: TTS exception: $e');
    }
  }

  /// Clear conversation history
  void clearHistory() {
    _conversationHistory.clear();
  }

  /// Clear audio buffer (e.g., on abort)
  void clearAudioBuffer() {
    _audioBuffer.clear();
  }

  /// Abort current processing
  void abort() {
    _audioBuffer.clear();
    _isProcessing = false;
  }
}
