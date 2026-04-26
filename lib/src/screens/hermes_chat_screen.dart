import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hermes_agent_app/src/providers/hermes_chat_provider.dart';
import 'package:hermes_agent_app/src/services/hermes_agent_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Main chat screen for Hermes Agent
class HermesChatScreen extends StatefulWidget {
  final String? initialConfig;

  const HermesChatScreen({super.key, this.initialConfig});

  @override
  State<HermesChatScreen> createState() => _HermesChatScreenState();
}

class _HermesChatScreenState extends State<HermesChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  late HermesChatProvider _provider;
  HermesAgentConfig? _config;
  bool _isConnected = false;
  bool _isConfigured = false;
  String _streamingContent = '';
  final List<ChatMessage> _displayMessages = [];
  
  StreamSubscription<ChatStreamUpdate>? _streamSubscription;
  StreamSubscription<HermesAgentException>? _errorSubscription;
  StreamSubscription<bool>? _loadingSubscription;

  @override
  void initState() {
    super.initState();
    _provider = HermesChatProvider();
    _loadConfiguration();
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    _errorSubscription?.cancel();
    _loadingSubscription?.cancel();
    _provider.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadConfiguration() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString('hermes_host');
    final port = prefs.getInt('hermes_port') ?? 8643;
    final useHttps = prefs.getBool('hermes_use_https') ?? false;
    final apiKey = prefs.getString('hermes_api_key');
    final sessionId = prefs.getString('hermes_session_id');

    if (host != null) {
      setState(() {
        _config = HermesAgentConfig(
          host: host,
          port: port,
          useHttps: useHttps,
          apiKey: apiKey,
          sessionId: sessionId,
        );
        _isConfigured = true;
      });
      
      _provider.initialize(_config!);
      _subscribeToStreams();
      await _checkConnection();
    }
  }

  Future<void> _checkConnection() async {
    if (_config == null) return;
    
    setState(() => _isConnected = false);
    
    final connected = await _provider.checkConnection();
    setState(() => _isConnected = connected);
    
    if (!connected && mounted) {
      _showErrorDialog('Connection Failed', 'Could not connect to Hermes Agent at ${_config!.host}:${_config!.port}');
    }
  }

  void _subscribeToStreams() {
    _streamSubscription = _provider.stream.listen((update) {
      if (update.delta != null) {
        setState(() {
          _streamingContent += update.delta!;
        });
        _scrollToBottom();
      }
      
      if (update.isComplete) {
        setState(() {
          _displayMessages.add(ChatMessage(
            role: 'assistant',
            content: _streamingContent,
            timestamp: DateTime.now(),
          ));
          _streamingContent = '';
        });
      }
    });

    _errorSubscription = _provider.errors.listen((error) {
      _showErrorDialog('Error', error.message);
    });

    _loadingSubscription = _provider.loadingStatus.listen((isLoading) {
      // Update UI loading state if needed
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _provider.isStreaming) return;

    _messageController.clear();
    
    // Add user message
    setState(() {
      _displayMessages.add(ChatMessage(
        role: 'user',
        content: text,
        timestamp: DateTime.now(),
      ));
    });

    try {
      await _provider.sendMessage(userMessage: text);
    } catch (e) {
      _showErrorDialog('Send Failed', e.toString());
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showConfigDialog() {
    final hostController = TextEditingController(text: _config?.host ?? '192.168.1.100');
    final portController = TextEditingController(text: _config?.port.toString() ?? '8643');
    final apiKeyController = TextEditingController(text: _config?.apiKey ?? '');
    final sessionIdController = TextEditingController(text: _config?.sessionId ?? '');
    bool useHttps = _config?.useHttps ?? false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Configure Hermes Agent'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: hostController,
                  decoration: const InputDecoration(
                    labelText: 'Host',
                    hintText: '192.168.1.100',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: portController,
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    hintText: '8643',
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('Use HTTPS'),
                    const Spacer(),
                    Switch(
                      value: useHttps,
                      onChanged: (value) {
                        setDialogState(() {
                          useHttps = value;
                          // Auto-switch port when toggling HTTPS
                          if (value) {
                            portController.text = '443';
                          } else {
                            portController.text = '8643';
                          }
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: apiKeyController,
                  decoration: const InputDecoration(
                    labelText: 'API Key (Optional)',
                    hintText: 'Bearer token if required',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: sessionIdController,
                  decoration: const InputDecoration(
                    labelText: 'Session ID (Optional)',
                    hintText: 'For stateless sessions',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                final newConfig = HermesAgentConfig(
                  host: hostController.text.trim(),
                  port: int.tryParse(portController.text.trim()) ?? (useHttps ? 443 : 8643),
                  useHttps: useHttps,
                  apiKey: apiKeyController.text.trim().isEmpty
                      ? null
                      : apiKeyController.text.trim(),
                  sessionId: sessionIdController.text.trim().isEmpty
                      ? null
                      : sessionIdController.text.trim(),
                );

                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('hermes_host', newConfig.host);
                await prefs.setInt('hermes_port', newConfig.port);
                await prefs.setBool('hermes_use_https', newConfig.useHttps);
                await prefs.setString('hermes_api_key', newConfig.apiKey ?? '');
                await prefs.setString('hermes_session_id', newConfig.sessionId ?? '');

              setState(() {
                _config = newConfig;
                _isConfigured = true;
              });

              _provider.initialize(newConfig);
              await _checkConnection();

              if (mounted) Navigator.pop(context);
            },
            child: const Text('Save & Test'),
          ),
        ],
      ),
    ));
  }

  void _showHistoryPanel() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Session History'),
        content: SizedBox(
          width: double.maxFinite,
          child: _displayMessages.isEmpty
              ? const Center(child: Text('No messages yet'))
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _displayMessages.length,
                  itemBuilder: (context, index) {
                    final msg = _displayMessages[index];
                    return ListTile(
                      leading: Icon(
                        msg.role == 'user' ? Icons.person : Icons.smart_toy,
                        color: msg.role == 'user' ? Colors.blue : Colors.green,
                      ),
                      title: Text(
                        msg.content.substring(0, msg.content.length > 50 ? 50 : msg.content.length),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${_formatTime(msg.timestamp)} - ${msg.role}',
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _displayMessages.clear();
                _provider.clearMessages();
              });
              Navigator.pop(context);
            },
            child: const Text('Clear All'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (!_isConfigured) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Hermes Agent'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.settings_remote, size: 64, color: Colors.grey),
              const SizedBox(height: 24),
              const Text(
                'Not Configured',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text(
                'Configure your Hermes Agent connection to get started',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _showConfigDialog,
                icon: const Icon(Icons.settings),
                label: const Text('Configure'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hermes Agent'),
        actions: [
          IconButton(
            icon: Icon(
              _isConnected ? Icons.wifi : Icons.wifi_off,
              color: _isConnected ? Colors.green : Colors.red,
            ),
            onPressed: _checkConnection,
            tooltip: _isConnected ? 'Connected' : 'Disconnected',
          ),
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: _showHistoryPanel,
            tooltip: 'History',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showConfigDialog,
            tooltip: 'Settings',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _displayMessages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 64,
                          color: Colors.grey[300],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Start chatting with Hermes Agent',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.grey[600],
                          ),
                        ),
                        if (!_isConnected) ...[
                          const SizedBox(height: 8),
                          Text(
                            '⚠️ Not connected',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.orange[700],
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _displayMessages.length + (_streamingContent.isNotEmpty ? 1 : 0),
                    itemBuilder: (context, index) {
                      final isStreaming = index == _displayMessages.length && _streamingContent.isNotEmpty;
                      final message = isStreaming
                          ? ChatMessage(role: 'assistant', content: _streamingContent)
                          : _displayMessages[index];

                      return _buildMessageBubble(message, isStreaming);
                    },
                  ),
          ),
          if (_streamingContent.isNotEmpty || _provider.isStreaming)
            const LinearProgressIndicator(),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message, bool isStreaming) {
    final isUser = message.role == 'user';
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            CircleAvatar(
              backgroundColor: Colors.green[100],
              child: const Icon(Icons.smart_toy, color: Colors.green),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isUser ? Colors.blue[100] : Colors.grey[200],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    message.content,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatTime(message.timestamp),
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 12),
            CircleAvatar(
              backgroundColor: Colors.blue[100],
              child: const Icon(Icons.person, color: Colors.blue),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withValues(alpha: 0.1),
            spreadRadius: 1,
            blurRadius: 3,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _messageController,
                decoration: InputDecoration(
                  hintText: 'Type a message...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                ),
                maxLines: null,
                textInputAction: TextInputAction.newline,
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              onPressed: _provider.isStreaming ? _provider.cancel : _sendMessage,
              icon: Icon(
                _provider.isStreaming ? Icons.stop : Icons.send,
                color: _provider.isStreaming ? Colors.red : Colors.blue,
              ),
              style: IconButton.styleFrom(
                backgroundColor: _provider.isStreaming ? Colors.red[100] : Colors.blue[100],
                padding: const EdgeInsets.all(12),
              ),
              tooltip: _provider.isStreaming ? 'Stop' : 'Send',
            ),
          ],
        ),
      ),
    );
  }
}
