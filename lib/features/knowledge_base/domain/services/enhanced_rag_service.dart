import 'package:flutter/foundation.dart';

import '../../../../data/local/app_database.dart';
import '../entities/knowledge_document.dart';
import 'enhanced_vector_search_service.dart';
import 'intelligent_retrieval_service.dart';
import 'embedding_service.dart';

/// 增强 RAG 提示词结果
class EnhancedRagPrompt {
  final String enhancedPrompt;
  final List<String> contexts;
  final int totalTokens;
  final double retrievalTime;
  final String? error;

  const EnhancedRagPrompt({
    required this.enhancedPrompt,
    required this.contexts,
    required this.totalTokens,
    required this.retrievalTime,
    this.error,
  });

  bool get isSuccess => error == null;

  @override
  String toString() {
    return 'EnhancedRagPrompt('
        'contexts: ${contexts.length}, '
        'tokens: $totalTokens, '
        'time: ${retrievalTime}ms, '
        'success: $isSuccess'
        ')';
  }
}

/// 增强 RAG 服务
///
/// 使用智能检索服务提供更高精度的检索增强生成功能
class EnhancedRagService {
  final AppDatabase _database;
  final EnhancedVectorSearchService _enhancedVectorSearchService;
  final IntelligentRetrievalService _intelligentRetrievalService;

  // 上下文缓存
  final Map<String, List<String>> _contextCache = {};
  final Map<String, DateTime> _cacheTimestamps = {};
  static const Duration _cacheExpiry = Duration(minutes: 15);
  static const int _maxCacheSize = 100;

  EnhancedRagService(
    this._database, 
    this._enhancedVectorSearchService,
    EmbeddingService embeddingService,
  ) : _intelligentRetrievalService = IntelligentRetrievalService(_database, embeddingService);

  /// 检索相关上下文
  Future<EnhancedRagRetrievalResult> retrieveContext({
    required String query,
    required KnowledgeBaseConfig config,
    String? knowledgeBaseId,
    double similarityThreshold = 0.3, // 降低默认阈值，提高召回率
    int maxContexts = 3,
  }) async {
    final startTime = DateTime.now();

    try {
      debugPrint('🔍 增强 RAG 检索上下文: "$query"');

      // 生成缓存键
      final cacheKey = _generateCacheKey(
        query,
        config.id,
        knowledgeBaseId,
        similarityThreshold,
        maxContexts,
      );

      // 检查缓存
      final cachedContexts = _getCachedContexts(cacheKey);
      if (cachedContexts != null) {
        debugPrint('🚀 使用缓存的上下文');
        return EnhancedRagRetrievalResult(
          contexts: cachedContexts,
          retrievalTime: _calculateRetrievalTime(startTime),
          totalResults: cachedContexts.length,
        );
      }

      // 执行智能检索
      final searchResult = await _intelligentRetrievalService.retrieve(
        query: query,
        config: config,
        knowledgeBaseId: knowledgeBaseId,
        maxResults: maxContexts,
        customThreshold: similarityThreshold,
      );

      if (!searchResult.isSuccess) {
        debugPrint('❌ 智能检索失败: ${searchResult.error}');
        
        // 回退到传统向量搜索
        debugPrint('🔄 回退到传统向量搜索...');
        final fallbackResult = await _enhancedVectorSearchService.search(
          query: query,
          config: config,
          knowledgeBaseId: knowledgeBaseId,
          similarityThreshold: similarityThreshold,
          maxResults: maxContexts,
        );
        
        if (!fallbackResult.isSuccess) {
          return EnhancedRagRetrievalResult(
            contexts: [],
            retrievalTime: _calculateRetrievalTime(startTime),
            totalResults: 0,
            error: '智能检索和向量搜索都失败: ${searchResult.error}',
          );
        }
        
        final fallbackContexts = fallbackResult.items.map((item) => item.content).toList();
        _cacheContexts(cacheKey, fallbackContexts);
        
        return EnhancedRagRetrievalResult(
          contexts: fallbackContexts,
          retrievalTime: _calculateRetrievalTime(startTime),
          totalResults: fallbackResult.items.length,
        );
      }

      // 提取上下文内容
      final contexts = searchResult.chunks.map((chunk) => chunk.content).toList();

      debugPrint('🎯 智能检索找到 ${contexts.length} 个高质量上下文');
      debugPrint('📊 检索策略: ${searchResult.searchStrategy}');

      // 输出检索结果的评分详情（前3个结果）
      for (int i = 0; i < searchResult.chunks.length && i < 3; i++) {
        final chunk = searchResult.chunks[i];
        debugPrint('   ${i + 1}. 最终分数: ${chunk.finalScore.toStringAsFixed(3)} '
                   '(向量: ${chunk.vectorScore.toStringAsFixed(3)}, '
                   '关键词: ${chunk.keywordScore.toStringAsFixed(3)}, '
                   '语义: ${chunk.semanticScore.toStringAsFixed(3)})');
      }

      // 缓存结果
      _cacheContexts(cacheKey, contexts);

      final retrievalTime = _calculateRetrievalTime(startTime);
      debugPrint(
        '✅ 智能检索完成，找到 ${contexts.length} 个高质量片段，耗时: ${retrievalTime}ms',
      );

      return EnhancedRagRetrievalResult(
        contexts: contexts,
        retrievalTime: retrievalTime,
        totalResults: searchResult.totalCandidates,
      );
    } catch (e) {
      final retrievalTime = _calculateRetrievalTime(startTime);
      debugPrint('❌ 上下文检索异常: $e');
      return EnhancedRagRetrievalResult(
        contexts: [],
        retrievalTime: retrievalTime,
        totalResults: 0,
        error: '上下文检索异常: $e',
      );
    }
  }

  /// 增强提示词
  Future<EnhancedRagPrompt> enhancePrompt({
    required String userQuery,
    required KnowledgeBaseConfig config,
    String? knowledgeBaseId,
    double similarityThreshold = 0.3, // 降低默认阈值，提高召回率
    int maxContexts = 3,
    String? systemPrompt,
  }) async {
    final startTime = DateTime.now();

    try {
      debugPrint('🤖 增强 RAG 提示词生成: "$userQuery"');

      // 检索相关上下文
      final retrievalResult = await retrieveContext(
        query: userQuery,
        config: config,
        knowledgeBaseId: knowledgeBaseId,
        similarityThreshold: similarityThreshold,
        maxContexts: maxContexts,
      );

      if (!retrievalResult.isSuccess) {
        debugPrint('❌ 上下文检索失败: ${retrievalResult.error}');
        return EnhancedRagPrompt(
          enhancedPrompt: systemPrompt ?? userQuery,
          contexts: [],
          totalTokens: _estimateTokens(systemPrompt ?? userQuery),
          retrievalTime: _calculateRetrievalTime(startTime),
          error: retrievalResult.error,
        );
      }

      // 构建增强提示词
      final enhancedPrompt = _buildEnhancedPrompt(
        userQuery: userQuery,
        contexts: retrievalResult.contexts,
        systemPrompt: systemPrompt,
      );

      final totalTokens = _estimateTokens(enhancedPrompt);
      final retrievalTime = _calculateRetrievalTime(startTime);

      debugPrint('✅ 增强提示词生成完成');
      debugPrint('📊 上下文数量: ${retrievalResult.contexts.length}');
      debugPrint('📊 预估令牌数: $totalTokens');
      debugPrint('📊 检索耗时: ${retrievalTime}ms');

      return EnhancedRagPrompt(
        enhancedPrompt: enhancedPrompt,
        contexts: retrievalResult.contexts,
        totalTokens: totalTokens,
        retrievalTime: retrievalTime,
      );
    } catch (e) {
      final retrievalTime = _calculateRetrievalTime(startTime);
      debugPrint('❌ 增强提示词生成异常: $e');
      return EnhancedRagPrompt(
        enhancedPrompt: systemPrompt ?? userQuery,
        contexts: [],
        totalTokens: _estimateTokens(systemPrompt ?? userQuery),
        retrievalTime: retrievalTime,
        error: '增强提示词生成异常: $e',
      );
    }
  }

  /// 获取知识库统计信息
  Future<Map<String, dynamic>> getKnowledgeBaseStats() async {
    try {
      debugPrint('📊 获取增强知识库统计信息...');

      // 获取数据库统计
      final documentsCount = await _database
          .select(_database.knowledgeDocumentsTable)
          .get();
      final chunksCount = await _database
          .select(_database.knowledgeChunksTable)
          .get();

      // 获取向量数据库健康状态
      final isVectorDbHealthy = await _enhancedVectorSearchService.isHealthy();

      final stats = {
        'totalDocuments': documentsCount.length,
        'totalChunks': chunksCount.length,
        'vectorDatabaseHealthy': isVectorDbHealthy,
        'cacheSize': _contextCache.length,
        'lastUpdated': DateTime.now().toIso8601String(),
      };

      debugPrint('✅ 知识库统计信息获取完成: $stats');
      return stats;
    } catch (e) {
      debugPrint('❌ 获取知识库统计信息失败: $e');
      return {
        'error': e.toString(),
        'totalDocuments': 0,
        'totalChunks': 0,
        'vectorDatabaseHealthy': false,
        'cacheSize': 0,
        'lastUpdated': DateTime.now().toIso8601String(),
      };
    }
  }

  /// 清理缓存
  void clearCache() {
    _contextCache.clear();
    _cacheTimestamps.clear();
    debugPrint('🧹 增强 RAG 缓存已清理');
  }

  // === 私有辅助方法 ===

  /// 生成缓存键
  String _generateCacheKey(
    String query,
    String configId,
    String? knowledgeBaseId,
    double similarityThreshold,
    int maxContexts,
  ) {
    return '$query|$configId|${knowledgeBaseId ?? 'default'}|$similarityThreshold|$maxContexts';
  }

  /// 获取缓存的上下文
  List<String>? _getCachedContexts(String cacheKey) {
    final timestamp = _cacheTimestamps[cacheKey];
    if (timestamp != null &&
        DateTime.now().difference(timestamp) < _cacheExpiry) {
      return _contextCache[cacheKey];
    }

    // 清理过期缓存
    _contextCache.remove(cacheKey);
    _cacheTimestamps.remove(cacheKey);
    return null;
  }

  /// 缓存上下文
  void _cacheContexts(String cacheKey, List<String> contexts) {
    // 限制缓存大小
    if (_contextCache.length >= _maxCacheSize) {
      final oldestKey = _cacheTimestamps.entries
          .reduce((a, b) => a.value.isBefore(b.value) ? a : b)
          .key;
      _contextCache.remove(oldestKey);
      _cacheTimestamps.remove(oldestKey);
    }

    _contextCache[cacheKey] = contexts;
    _cacheTimestamps[cacheKey] = DateTime.now();
  }

  /// 构建增强提示词
  String _buildEnhancedPrompt({
    required String userQuery,
    required List<String> contexts,
    String? systemPrompt,
  }) {
    final buffer = StringBuffer();

    // 添加系统提示词
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      buffer.writeln(systemPrompt);
      buffer.writeln();
    }

    // 添加上下文信息
    if (contexts.isNotEmpty) {
      buffer.writeln('以下是相关的背景信息：');
      buffer.writeln();

      for (int i = 0; i < contexts.length; i++) {
        buffer.writeln('【参考资料 ${i + 1}】');
        buffer.writeln(contexts[i]);
        buffer.writeln();
      }

      buffer.writeln('请基于以上背景信息回答用户的问题。如果背景信息不足以回答问题，请诚实说明。');
      buffer.writeln();
    }

    // 添加用户查询
    buffer.writeln('用户问题：$userQuery');

    return buffer.toString();
  }

  /// 估算令牌数量（简单估算：1个中文字符≈1.5个令牌，1个英文单词≈1个令牌）
  int _estimateTokens(String text) {
    final chineseChars = text.runes
        .where((rune) => rune > 0x4E00 && rune < 0x9FFF)
        .length;
    final englishWords = text
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .length;
    return (chineseChars * 1.5 + englishWords).round();
  }

  /// 计算检索时间
  double _calculateRetrievalTime(DateTime startTime) {
    return DateTime.now().difference(startTime).inMilliseconds.toDouble();
  }
}

/// 增强 RAG 检索结果
class EnhancedRagRetrievalResult {
  final List<String> contexts;
  final double retrievalTime;
  final int totalResults;
  final String? error;

  const EnhancedRagRetrievalResult({
    required this.contexts,
    required this.retrievalTime,
    required this.totalResults,
    this.error,
  });

  bool get isSuccess => error == null;

  @override
  String toString() {
    return 'EnhancedRagRetrievalResult('
        'contexts: ${contexts.length}, '
        'totalResults: $totalResults, '
        'time: ${retrievalTime}ms, '
        'success: $isSuccess'
        ')';
  }
}
