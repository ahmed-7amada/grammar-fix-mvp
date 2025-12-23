import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fllama/fllama.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Grammar Fix MVP',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const GrammarFixScreen(),
    );
  }
}

class GrammarFixScreen extends StatefulWidget {
  const GrammarFixScreen({super.key});

  @override
  State<GrammarFixScreen> createState() => _GrammarFixScreenState();
}

class _GrammarFixScreenState extends State<GrammarFixScreen> {
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _outputController = TextEditingController();

  bool _isDownloading = false;
  bool _isModelReady = false;
  bool _isProcessing = false;
  double _downloadProgress = 0.0;
  String _statusMessage = 'Model not downloaded';

  String? _modelPath;

  static const String modelUrl =
    'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf';
  static const String modelFilename = 'llama-3.2-1b-q4.gguf';

  @override
  void initState() {
    super.initState();
    _checkModelExists();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _outputController.dispose();
    super.dispose();
  }

  Future<String> _getModelPath() async {
    final appDir = await getApplicationDocumentsDirectory();
    final modelDir = Directory('${appDir.path}/models');
    if (!await modelDir.exists()) {
      await modelDir.create(recursive: true);
    }
    return '${modelDir.path}/$modelFilename';
  }

  Future<void> _checkModelExists() async {
    final modelPath = await _getModelPath();
    final file = File(modelPath);

    if (await file.exists()) {
      setState(() {
        _modelPath = modelPath;
        _statusMessage = 'Model ready. Initializing...';
      });
      await _initializeModel();
    } else {
      setState(() {
        _statusMessage = 'Model not downloaded (~700 MB)';
      });
    }
  }

  Future<void> _downloadModel() async {
    setState(() {
      _isDownloading = true;
      _statusMessage = 'Downloading model...';
      _downloadProgress = 0.0;
    });

    try {
      final modelPath = await _getModelPath();
      final dio = Dio();

      await dio.download(
        modelUrl,
        modelPath,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            setState(() {
              _downloadProgress = received / total;
              _statusMessage = 'Downloading: ${(received / 1024 / 1024).toStringAsFixed(1)} MB / ${(total / 1024 / 1024).toStringAsFixed(1)} MB';
            });
          }
        },
      );

      setState(() {
        _modelPath = modelPath;
        _statusMessage = 'Download complete. Initializing model...';
      });

      await _initializeModel();

    } catch (e) {
      setState(() {
        _statusMessage = 'Download failed: $e';
        _isDownloading = false;
      });
    }
  }

  Future<void> _initializeModel() async {
    try {
      if (_modelPath == null) return;

      // With fllama, the model loads automatically when fllamaChat is called
      // We just need to mark it as ready since the file exists
      setState(() {
        _isModelReady = true;
        _isDownloading = false;
        _statusMessage = 'Model ready!';
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Model initialization failed: $e';
        _isDownloading = false;
        _isModelReady = false;
      });
    }
  }

  Future<void> _rewriteText() async {
    if (!_isModelReady) {
      _showError('Model is not ready yet');
      return;
    }

    final inputText = _inputController.text.trim();
    if (inputText.isEmpty) {
      _showError('Please enter some text');
      return;
    }

    setState(() {
      _isProcessing = true;
      _outputController.text = 'Rewriting...';
    });

    try {
      final request = OpenAiRequest(
        maxTokens: 512,
        messages: [
          Message(
            Role.system,
            'You are a professional writing assistant. Your task is to completely rewrite and improve the text provided by the user. Make it clearer, more engaging, and professionally written while preserving the original meaning. Return ONLY the rewritten text without any explanations.',
          ),
          Message(
            Role.user,
            'Rewrite the following text: $inputText',
          ),
        ],
        modelPath: _modelPath!,
        temperature: 0.7,
        topP: 0.9,
      );

      await fllamaChat(request, (response, responseJson, done) {
        String cleanResponse = response
            .replaceAll(RegExp(r'<\|eot_id\|>'), '')
            .replaceAll(RegExp(r'<\|start_header_id\|>'), '')
            .replaceAll(RegExp(r'<\|end_header_id\|>'), '')
            .replaceAll(RegExp(r'\b(system|user|assistant)\b'), '')
            .trim();

        if (done) {
          print('✅ Rewrite completed');
          print('Final result: $cleanResponse');
          setState(() {
            _outputController.text = cleanResponse;
            _isProcessing = false;
          });
        } else {
          print('Streaming: $cleanResponse');
          setState(() {
            _outputController.text = cleanResponse;
          });
        }
      });
    } catch (e) {
      setState(() {
        _outputController.text = 'Error: $e';
        _isProcessing = false;
      });
    }
  }

  Future<void> _fixGrammar() async {
    if (!_isModelReady) {
      _showError('Model is not ready yet');
      return;
    }

    final inputText = _inputController.text.trim();
    if (inputText.isEmpty) {
      _showError('Please enter some text');
      return;
    }

    setState(() {
      _isProcessing = true;
      _outputController.text = 'Processing...';
    });

    try {
      // Create chat request with system and user messages
      final request = OpenAiRequest(
        maxTokens: 256,
        messages: [
          Message(
            Role.system,
            'You are a grammar correction assistant. Your task is to correct grammar, spelling, and punctuation errors in the text provided by the user. Return ONLY the corrected text without any explanations or additional commentary.',
          ),
          Message(
            Role.user,
            'Correct the following text: $inputText',
          ),
        ],
        modelPath: _modelPath!,
        temperature: 0.1,
        topP: 0.95,
      );

      // Use fllamaChat for streaming response
      await fllamaChat(request, (response, responseJson, done) {
        // Clean Llama 3.2 chat template tokens from response
        String cleanResponse = response
            .replaceAll(RegExp(r'<\|eot_id\|>'), '')
            .replaceAll(RegExp(r'<\|start_header_id\|>'), '')
            .replaceAll(RegExp(r'<\|end_header_id\|>'), '')
            .replaceAll(RegExp(r'\b(system|user|assistant)\b'), '')
            .trim();

        if (done) {
          print('✅ Grammar correction completed');
          print('Final result: $cleanResponse');
          setState(() {
            _outputController.text = cleanResponse;
            _isProcessing = false;
          });
        } else {
          print('Streaming: $cleanResponse');
          setState(() {
            _outputController.text = cleanResponse;
          });
        }
      });
    } catch (e) {
      setState(() {
        _outputController.text = 'Error: $e';
        _isProcessing = false;
      });
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Grammar Fix MVP'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status Card
              Card(
                color: _isModelReady ? Colors.green[50] : Colors.orange[50],
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Text(
                        _statusMessage,
                        style: const TextStyle(fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                      if (_isDownloading) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(value: _downloadProgress),
                      ],
                      if (!_isModelReady && !_isDownloading) ...[
                        const SizedBox(height: 8),
                        ElevatedButton(
                          onPressed: _downloadModel,
                          child: const Text('Download Model (~700 MB)'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Input Text Field
              const Text('Input Text:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _inputController,
                maxLines: 5,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Enter text to fix grammar...\ne.g., "I goes to school yesterday"',
                ),
                enabled: _isModelReady,
              ),
              const SizedBox(height: 16),

              // Action Buttons Row
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isModelReady && !_isProcessing ? _fixGrammar : null,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                      ),
                      child: Text(
                        _isProcessing ? 'Processing...' : 'Fix Grammar',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isModelReady && !_isProcessing ? _rewriteText : null,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        backgroundColor: Colors.deepPurple,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(
                        _isProcessing ? 'Processing...' : 'Rewrite',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Output Text Field
              const Text('Corrected Text:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              SizedBox(
                height: 200,
                child: TextField(
                  controller: _outputController,
                  maxLines: null,
                  expands: true,
                  readOnly: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Corrected text will appear here...',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
