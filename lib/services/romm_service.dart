import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as path;

import '../models/romm_platform.dart';
import '../models/romm_rom.dart';
import 'logger_service.dart';

/// Raised when a RomM API call fails; [message] is safe to surface to the user.
class RommException implements Exception {
  final String message;
  final int? statusCode;
  RommException(this.message, {this.statusCode});

  @override
  String toString() => 'RommException($statusCode): $message';
}

/// HTTP client for a remote RomM server (library browse + ROM download).
///
/// Holds the server base URL and JWT tokens for one connection and transparently
/// refreshes the access token on expiry / 401. Auth is OAuth2 password grant
/// (`POST /api/token`). Modeled on the IOClient + bad-certificate setup used by
/// [ScreenScraperService] so self-signed homelab certificates work.
class RommService {
  static final _log = LoggerService.instance;

  /// Read scopes requested in the password grant. RomM grants the intersection
  /// of these and the user's allowed scopes; covers library browse + download.
  static const String _readScopes =
      'me.read roms.read platforms.read assets.read collections.read firmware.read';

  /// Shared client that tolerates self-signed certificates (homelab servers).
  static final http.Client _httpClient = () {
    final inner = HttpClient()
      ..badCertificateCallback =
          ((X509Certificate cert, String host, int port) => true);
    return IOClient(inner);
  }();

  String _baseUrl = '';

  /// Whether the user pinned the scheme (`http://`/`https://`) themselves. When
  /// false we may transparently downgrade an https attempt to http on a TLS
  /// handshake failure (common for plain-HTTP homelab servers).
  bool _schemeExplicit = false;
  String _username = '';
  String _password = '';
  String? _accessToken;
  String? _refreshToken;
  int? _tokenExpiresMs;

  String get baseUrl => _baseUrl;
  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;
  int? get tokenExpiresMs => _tokenExpiresMs;

  /// Configures the connection. [serverUrl] may include or omit a scheme and
  /// trailing slash; it is normalized to `scheme://host[:port]` with no
  /// trailing slash. Existing tokens (if any) can be restored via
  /// [accessToken]/[refreshToken]/[tokenExpiresMs].
  void configure({
    required String serverUrl,
    required String username,
    required String password,
    String? accessToken,
    String? refreshToken,
    int? tokenExpiresMs,
  }) {
    final raw = serverUrl.trim();
    _schemeExplicit = raw.startsWith('http://') || raw.startsWith('https://');
    _baseUrl = _normalizeBaseUrl(raw);
    _username = username;
    _password = password;
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _tokenExpiresMs = tokenExpiresMs;
  }

  static String _normalizeBaseUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Uri _uri(String pathAndQuery) => Uri.parse('$_baseUrl$pathAndQuery');

  bool get _tokenLikelyValid {
    if (_accessToken == null || _accessToken!.isEmpty) return false;
    final exp = _tokenExpiresMs;
    if (exp == null) return true; // assume valid until a 401 proves otherwise
    // Refresh 30s early to avoid edge-of-expiry races.
    return DateTime.now().millisecondsSinceEpoch < exp - 30000;
  }

  // ── Authentication ─────────────────────────────────────────────────────────

  /// POSTs to `/api/token`. If an HTTPS TLS handshake fails and the user did
  /// not pin the scheme, downgrades the base URL to HTTP and retries once
  /// (plain-HTTP homelab servers are common).
  Future<http.Response> _postTokenRequest(Map<String, String> body) async {
    const headers = {'Content-Type': 'application/x-www-form-urlencoded'};
    try {
      return await _httpClient
          .post(_uri('/api/token'), headers: headers, body: body)
          .timeout(const Duration(seconds: 30));
    } on HandshakeException {
      if (!_schemeExplicit && _baseUrl.startsWith('https://')) {
        _baseUrl = _baseUrl.replaceFirst('https://', 'http://');
        _log.w('RomM HTTPS handshake failed; retrying over HTTP at $_baseUrl');
        return await _httpClient
            .post(_uri('/api/token'), headers: headers, body: body)
            .timeout(const Duration(seconds: 30));
      }
      rethrow;
    }
  }

  /// Performs the OAuth2 password grant and stores the resulting tokens.
  /// Throws [RommException] with a user-facing message on failure.
  Future<void> authenticate() async {
    if (_baseUrl.isEmpty) {
      throw RommException('Server URL is empty');
    }
    final body = {
      'grant_type': 'password',
      'username': _username,
      'password': _password,
      // RomM issues an empty-scope token (403 on every read endpoint) unless
      // the requested scopes are passed explicitly.
      'scope': _readScopes,
    };

    http.Response resp;
    try {
      resp = await _postTokenRequest(body);
    } on TimeoutException {
      throw RommException('Connection timed out');
    } on HandshakeException {
      throw RommException(
        'TLS handshake failed — try an http:// URL if the server is not HTTPS',
      );
    } on SocketException catch (e) {
      throw RommException('Cannot reach server: ${e.message}');
    } catch (e) {
      throw RommException('Connection failed: $e');
    }

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw RommException(
        'Invalid username or password',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode != 200) {
      throw RommException(
        'Authentication failed (${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }

    _applyTokenResponse(resp.body);
  }

  Future<void> _refreshAccessToken() async {
    final refresh = _refreshToken;
    if (refresh == null || refresh.isEmpty) {
      // No refresh token: fall back to a full re-authentication.
      await authenticate();
      return;
    }
    try {
      final resp = await _postTokenRequest({
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
      });
      if (resp.statusCode == 200) {
        _applyTokenResponse(resp.body);
        return;
      }
    } catch (e) {
      _log.w('RomM token refresh failed, re-authenticating: $e');
    }
    // Refresh failed for any reason: re-authenticate from credentials.
    await authenticate();
  }

  void _applyTokenResponse(String responseBody) {
    final json = jsonDecode(responseBody) as Map<String, dynamic>;
    final access = json['access_token']?.toString();
    if (access == null || access.isEmpty) {
      throw RommException('Server did not return an access token');
    }
    _accessToken = access;
    final refresh = json['refresh_token']?.toString();
    if (refresh != null && refresh.isNotEmpty) {
      _refreshToken = refresh;
    }
    // `expires` is the access-token lifetime in seconds.
    final expiresSeconds = (json['expires'] as num?)?.toInt();
    _tokenExpiresMs = expiresSeconds != null
        ? DateTime.now().millisecondsSinceEpoch + expiresSeconds * 1000
        : null;
  }

  /// Ensures a usable access token, authenticating or refreshing as needed.
  Future<void> _ensureToken() async {
    if (_tokenLikelyValid) return;
    if (_accessToken != null && _refreshToken != null) {
      await _refreshAccessToken();
    } else {
      await authenticate();
    }
  }

  Map<String, String> get _authHeaders => {
    'Authorization': 'Bearer $_accessToken',
  };

  /// Authenticates and performs a lightweight call to confirm the connection
  /// and credentials are valid (used by the settings "Test" button).
  Future<void> verifyConnection() async {
    await authenticate();
    // A successful, authorized call confirms the token works end-to-end.
    await getPlatforms();
  }

  // ── Read endpoints ───────────────────────────────────────────────────────

  /// Issues an authenticated GET, refreshing the token once on a 401.
  Future<http.Response> _authedGet(String pathAndQuery) async {
    await _ensureToken();
    http.Response resp;
    try {
      resp = await _httpClient
          .get(_uri(pathAndQuery), headers: _authHeaders)
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw RommException('Request timed out');
    } on SocketException catch (e) {
      throw RommException('Cannot reach server: ${e.message}');
    }

    if (resp.statusCode == 401) {
      // Token may have been revoked/expired server-side: refresh and retry once.
      await _refreshAccessToken();
      resp = await _httpClient
          .get(_uri(pathAndQuery), headers: _authHeaders)
          .timeout(const Duration(seconds: 30));
    }

    if (resp.statusCode != 200) {
      throw RommException(
        'Request failed (${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }
    return resp;
  }

  /// Returns all platforms (consoles/systems) on the server.
  Future<List<RommPlatform>> getPlatforms() async {
    final resp = await _authedGet('/api/platforms');
    final decoded = jsonDecode(resp.body);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(RommPlatform.fromJson)
        .toList();
  }

  /// Returns one page of ROMs for [platformId]. RomM paginates via
  /// `limit`/`offset`; [search] filters by name server-side.
  Future<List<RommRom>> getRoms(
    int platformId, {
    String? search,
    int limit = 50,
    int offset = 0,
  }) async {
    final params = <String, String>{
      // RomM filters by the plural `platform_ids`; `platform_id` is ignored.
      'platform_ids': '$platformId',
      'limit': '$limit',
      'offset': '$offset',
      'order_by': 'name',
    };
    if (search != null && search.trim().isNotEmpty) {
      params['search_term'] = search.trim();
    }
    final query = params.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    final resp = await _authedGet('/api/roms?$query');
    final decoded = jsonDecode(resp.body);
    // RomM may return either a bare list or a paginated `{items: [...]}` object.
    final List items;
    if (decoded is List) {
      items = decoded;
    } else if (decoded is Map && decoded['items'] is List) {
      items = decoded['items'] as List;
    } else {
      items = const [];
    }
    return items
        .whereType<Map<String, dynamic>>()
        .map(RommRom.fromJson)
        .toList();
  }

  /// Returns full detail for a single ROM.
  Future<RommRom> getRom(int id) async {
    final resp = await _authedGet('/api/roms/$id');
    return RommRom.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Returns the raw ROM-detail JSON (metadata + media paths), or null on error.
  /// Used by the metadata import, which needs fields beyond [RommRom].
  Future<Map<String, dynamic>?> getRomDetail(int id) async {
    try {
      final resp = await _authedGet('/api/roms/$id');
      final decoded = jsonDecode(resp.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      _log.e('RomM getRomDetail failed: $e');
      return null;
    }
  }

  /// Fetches raw image bytes (RomM-relative path or absolute URL), or null.
  /// The caller picks the on-disk extension from the actual content — RomM
  /// serves JPEG even from `*.png` cover paths, and the app's image lookup is
  /// extension-sensitive.
  Future<Uint8List?> fetchImageBytes(String pathOrUrl) async {
    try {
      final url = pathOrUrl.startsWith('http')
          ? pathOrUrl
          : '$_baseUrl${pathOrUrl.startsWith('/') ? '' : '/'}$pathOrUrl';
      final resp = await _httpClient
          .get(Uri.parse(url), headers: imageHeadersFor(url))
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return null;
      return resp.bodyBytes;
    } catch (e) {
      _log.e('RomM image fetch failed: $e');
      return null;
    }
  }

  /// Returns the image file extension ('jpg'/'png'/'webp') implied by [bytes]'
  /// magic numbers, defaulting to 'png'.
  static String imageExtensionFor(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'jpg';
    }
    if (bytes.length >= 12 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    return 'png';
  }

  /// Builds an absolute, authenticated-fetchable cover URL for [rom], or null.
  String? coverUrl(RommRom rom) {
    final cover = rom.urlCover;
    if (cover == null || cover.isEmpty) return null;
    if (cover.startsWith('http://') || cover.startsWith('https://')) {
      return cover;
    }
    return '$_baseUrl${cover.startsWith('/') ? '' : '/'}$cover';
  }

  /// Absolute logo URL for [platform] (usually a public IGDB CDN URL), or null.
  String? platformLogoUrl(RommPlatform platform) {
    final logo = platform.urlLogo;
    if (logo == null || logo.isEmpty) return null;
    if (logo.startsWith('http://') || logo.startsWith('https://')) {
      return logo;
    }
    return '$_baseUrl${logo.startsWith('/') ? '' : '/'}$logo';
  }

  /// Auth headers for fetching an image, but only when [url] points at the RomM
  /// server itself — never leak the bearer token to third-party CDNs (IGDB,
  /// RetroAchievements, etc. host many covers/logos).
  Map<String, String> imageHeadersFor(String url) =>
      (_accessToken != null && url.startsWith(_baseUrl))
      ? _authHeaders
      : const {};

  /// URL of RomM's bundled SVG icon for [platform]. RomM only ships icons for
  /// some slugs, so this may 404.
  String platformIconUrl(RommPlatform platform) =>
      '$_baseUrl/assets/platforms/${platform.slug}.svg';

  /// Fetches an SVG document, returning its source if it looks like SVG, else
  /// null (e.g. a 404 for a slug RomM has no icon for).
  ///
  /// RomM's icons are Illustrator exports that style shapes via `<style>` CSS
  /// classes, which flutter_svg ignores (everything would render solid black),
  /// so we inline those class styles as presentation attributes first.
  Future<String?> fetchSvg(String url) async {
    try {
      final resp = await _httpClient
          .get(Uri.parse(url), headers: imageHeadersFor(url))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200 && resp.body.contains('<svg')) {
        return _inlineSvgClassStyles(resp.body);
      }
    } catch (_) {
      // Network/parse failure: fall through to null so the UI uses a fallback.
    }
    return null;
  }

  /// Converts `<style>`-block class rules into inline presentation attributes so
  /// renderers without CSS support draw the intended fills/strokes. Handles
  /// multi-selector rules and elements carrying several classes.
  static String _inlineSvgClassStyles(String svg) {
    final styleMatch = RegExp(
      r'<style[^>]*>(.*?)</style>',
      dotAll: true,
    ).firstMatch(svg);
    if (styleMatch == null) return svg;

    final classProps = <String, Map<String, String>>{};
    final ruleRe = RegExp(r'([^{}]+)\{([^{}]+)\}');
    for (final rule in ruleRe.allMatches(styleMatch.group(1)!)) {
      final props = <String, String>{};
      for (final decl in rule.group(2)!.split(';')) {
        final i = decl.indexOf(':');
        if (i < 0) continue;
        final key = decl.substring(0, i).trim();
        final value = decl.substring(i + 1).trim();
        if (key.isNotEmpty && value.isNotEmpty) props[key] = value;
      }
      if (props.isEmpty) continue;
      for (final sel in rule.group(1)!.split(',')) {
        final s = sel.trim();
        if (!s.startsWith('.')) continue;
        classProps.putIfAbsent(s.substring(1), () => {}).addAll(props);
      }
    }
    if (classProps.isEmpty) return svg;

    return svg.replaceAllMapped(RegExp(r'class="([^"]+)"'), (m) {
      final merged = <String, String>{};
      for (final c in m.group(1)!.trim().split(RegExp(r'\s+'))) {
        final p = classProps[c];
        if (p != null) merged.addAll(p);
      }
      if (merged.isEmpty) return m.group(0)!;
      final attrs = merged.entries
          .map((e) => '${e.key}="${e.value}"')
          .join(' ');
      return '${m.group(0)} $attrs';
    });
  }

  // ── Download ─────────────────────────────────────────────────────────────

  /// Streams a ROM download to [destFilePath].
  ///
  /// Writes to a sibling `.part` temp file and renames it into place only on
  /// success, so partial/cancelled downloads never leave a usable-looking file.
  /// Streaming (not buffering) keeps memory flat for multi-GB ROMs.
  ///
  /// [onProgress] receives `(receivedBytes, totalBytes?)`. [shouldCancel] is
  /// polled between chunks; returning true aborts and cleans up the temp file.
  Future<void> downloadRom(
    RommRom rom, {
    required String destFilePath,
    void Function(int received, int? total)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    await _ensureToken();

    final fileName = rom.fsName.isNotEmpty ? rom.fsName : '${rom.id}';
    final endpoint =
        '/api/roms/${rom.id}/content/${Uri.encodeComponent(fileName)}';

    final tmpPath = '$destFilePath.part';
    final tmpFile = File(tmpPath);
    if (await tmpFile.exists()) {
      await tmpFile.delete();
    }
    await Directory(path.dirname(destFilePath)).create(recursive: true);

    final request = http.Request('GET', _uri(endpoint));
    request.headers.addAll(_authHeaders);

    http.StreamedResponse resp;
    try {
      resp = await _httpClient.send(request);
    } on SocketException catch (e) {
      throw RommException('Cannot reach server: ${e.message}');
    }

    if (resp.statusCode == 401) {
      await _refreshAccessToken();
      final retry = http.Request('GET', _uri(endpoint))
        ..headers.addAll(_authHeaders);
      resp = await _httpClient.send(retry);
    }

    if (resp.statusCode != 200) {
      throw RommException(
        'Download failed (${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }

    final total = resp.contentLength;
    var received = 0;
    final sink = tmpFile.openWrite();
    try {
      await for (final chunk in resp.stream) {
        if (shouldCancel?.call() ?? false) {
          await sink.close();
          await tmpFile.delete();
          throw RommException('Download cancelled');
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (await tmpFile.exists()) {
        await tmpFile.delete();
      }
      if (e is RommException) rethrow;
      throw RommException('Download error: $e');
    }

    // Replace any existing destination, then move temp into place.
    final destFile = File(destFilePath);
    if (await destFile.exists()) {
      await destFile.delete();
    }
    await tmpFile.rename(destFilePath);
    _log.i('RomM download complete: $destFilePath ($received bytes)');
  }
}
