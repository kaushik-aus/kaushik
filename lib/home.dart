import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'config.dart'; // use shared config instead of importing main.dart
import 'dart:async'; // Add this import for Timer
import 'WishList_page/wishlist.dart'; // already imported
import 'pages/issued_books_page.dart'; // added
import 'pages/pay_fine_page.dart'; // added

// Two-color mixed background (aesthetic gradient)
// Feel free to tweak these four colors; the background animates between pairs.
const _bgA1 = Color.fromARGB(255, 193, 241, 151);
const _bgA2 = Color.fromARGB(255, 150, 196, 118);
const _bgB1 = Color.fromARGB(255, 228, 185, 204);
const _bgB2 = Color(0xFFF472B6);

// Text colors for light pastel cards
const _ink = Color(0xFF1F2544);
const _muted = Color(0xFF6B7280);
// Accent
const _accent = Color(0xFF5B6BFF);

class HomePage extends StatefulWidget {
  final bool useAltBackground;
  final String username;
  final String? userBarcode; // propagated from login for reliable lookups

  const HomePage({
    Key? key,
    required this.useAltBackground,
    required this.username,
    this.userBarcode,
  }) : super(key: key);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  List<Map<String, String>> _issuedBooks = [];
  // Keep search results separate so "Issued Books" never changes due to search
  List<Map<String, String>> _searchResults = [];
  bool _isBooksLoading = false;
  List<String> _searchSuggestions = [];
  bool _showSuggestions = false;
  String _searchQuery = '';

  // Overlay dropdown plumbing
  final LayerLink _layerLink = LayerLink();
  final FocusNode _searchFocusNode = FocusNode();
  final TextEditingController _searchController = TextEditingController();
  OverlayEntry? _suggestionsOverlay;

  Timer? _debounce;
  bool _isTyping = false;
  bool _isSearchLoading = false; // Add this
  // Add: refresh indicator key
  final GlobalKey<RefreshIndicatorState> _refreshKey =
      GlobalKey<RefreshIndicatorState>();

  // Open drawer safely
  void _openDrawer() {
    try {
      _scaffoldKey.currentState?.openDrawer();
    } catch (e) {
      debugPrint('Error opening drawer: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open menu')));
    }
  }

  // Launch website robustly
  Future<void> _launchWebsite(Uri url) async {
    try {
      bool launched = await launchUrl(url, mode: LaunchMode.platformDefault);
      if (!launched) {
        launched = await launchUrl(url, mode: LaunchMode.externalApplication);
      }
      if (!launched) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not open the website. Please check your internet connection.',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Launch error: ${e.toString()}')));
    }
  }

  // Profile bottom sheet
  void _openProfile(BuildContext context) {
    Navigator.pop(context);
    final ctx = _scaffoldKey.currentContext ?? context;
    final String initial = widget.username.trim().isEmpty
        ? '?'
        : widget.username.trim()[0].toUpperCase();

    showModalBottomSheet(
      context: ctx,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 34,
                backgroundColor: _accent,
                child: Text(
                  initial,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 30,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                widget.username,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: _ink,
                ),
              ),
              const SizedBox(height: 6),
              const Text('Profile', style: TextStyle(color: Colors.black54)),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit profile (coming soon)'),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(
                        content: Text('Edit profile not implemented'),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.close),
                  label: const Text('Close'),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _fetchIssuedBooks();
    _searchFocusNode.addListener(() {
      if (!_searchFocusNode.hasFocus) {
        _hideSuggestionsOverlay();
      }
    });
  }

  @override
  void dispose() {
    _hideSuggestionsOverlay();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  // Debounce function to delay search
  void _onSearchChanged(String query) {
    _searchQuery = query;

    if (_debounce?.isActive ?? false) _debounce!.cancel();

    if (query.trim().isEmpty) {
      _hideSuggestionsOverlay();
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _fetchSearchSuggestions(query);
    });
  }

  // Update to fetch suggestions from Booklog table
  Future<void> _fetchSearchSuggestions(String query) async {
    if (query.trim().isEmpty) return;

    try {
      setState(() {
        _isSearchLoading = true;
      });

      final baseUrl = djangoBaseUrl.endsWith('/')
          ? djangoBaseUrl.substring(0, djangoBaseUrl.length - 1)
          : djangoBaseUrl;

      final url = Uri.parse(
        '$baseUrl/book-suggestions/?search=${Uri.encodeComponent(query)}',
      );

      final response = await http.get(url).timeout(const Duration(seconds: 2));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);

        setState(() {
          _searchSuggestions = data
              .map<String>((item) => item['book_title']?.toString() ?? '')
              .where((title) => title.isNotEmpty)
              .toList();

          if (_searchSuggestions.isEmpty) {
            _fetchFallbackSuggestions(query);
          } else {
            _showSuggestions = true;
            _isSearchLoading = false;
            if (_searchFocusNode.hasFocus) {
              _showSearchSuggestionsOverlay();
            }
          }
        });
      } else {
        _fetchFallbackSuggestions(query);
      }
    } catch (e) {
      debugPrint('Fetch suggestions error: $e');
      _fetchFallbackSuggestions(query);
    }
  }

  // Fallback to get suggestions from main book-log endpoint
  Future<void> _fetchFallbackSuggestions(String query) async {
    try {
      final baseUrl = djangoBaseUrl.endsWith('/')
          ? djangoBaseUrl.substring(0, djangoBaseUrl.length - 1)
          : djangoBaseUrl;

      final url = Uri.parse(
        '$baseUrl/book-log/?search=${Uri.encodeComponent(query)}',
      );

      final response = await http.get(url).timeout(const Duration(seconds: 2));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);

        setState(() {
          _searchSuggestions = data
              .map<String>((item) => item['book_title']?.toString() ?? '')
              .where((title) => title.isNotEmpty)
              .toList();

          _showSuggestions = true;
          _isSearchLoading = false;

          if (_searchFocusNode.hasFocus && _searchSuggestions.isNotEmpty) {
            _showSearchSuggestionsOverlay();
          }
        });
      } else {
        setState(() => _isSearchLoading = false);
      }
    } catch (e) {
      debugPrint('Fallback suggestions error: $e');
      if (mounted) setState(() => _isSearchLoading = false);
    }
  }

  // Simple search implementation
  Future<void> _executeSimpleSearch(String query) async {
    try {
      setState(() {
        _isSearchLoading = true;
        _hideSuggestionsOverlay();
      });

      final baseUrl = djangoBaseUrl.endsWith('/')
          ? djangoBaseUrl.substring(0, djangoBaseUrl.length - 1)
          : djangoBaseUrl;

      final url = Uri.parse(
        '$baseUrl/book-log/?search=${Uri.encodeComponent(query)}',
      );

      final response = await http.get(url).timeout(const Duration(seconds: 5));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);

        setState(() {
          _searchResults = data
              .map<Map<String, String>>(
                (item) => {
                  'title': item['book_title']?.toString() ?? '',
                  'author':
                      item['book_author']?.toString() ??
                      item['auther']?.toString() ??
                      '',
                  'isbn': item['book_isbn']?.toString() ?? '',
                  'publisher': item['book_publisher']?.toString() ?? '',
                  'cover': item['book_cover']?.toString() ?? '',
                },
              )
              .toList();
          _isSearchLoading = false;
        });
      } else {
        if (!mounted) return;
        setState(() => _isSearchLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error searching books: ${response.statusCode}'),
          ),
        );
      }
    } catch (e) {
      debugPrint('Search error: $e');
      if (!mounted) return;
      setState(() => _isSearchLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Search error: Network or server issue')),
      );
    }
  }

  // Suggestions overlay
  void _showSearchSuggestionsOverlay() {
    _hideSuggestionsOverlay();

    final overlay = Overlay.of(context);

    _suggestionsOverlay = OverlayEntry(
      builder: (context) => Positioned(
        width: MediaQuery.of(context).size.width - 32,
        top: MediaQuery.of(context).padding.top + 190,
        left: 16,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0.0, 30.0),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            color: const Color(0xFF2A2A2A),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.4,
              ),
              child: _isSearchLoading
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    )
                  : _searchSuggestions.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'No books found',
                        style: TextStyle(color: Colors.white70),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: _searchSuggestions.length,
                      itemBuilder: (context, index) {
                        return ListTile(
                          leading: const Icon(
                            Icons.book_outlined,
                            color: Colors.white54,
                            size: 20,
                          ),
                          minLeadingWidth: 20,
                          dense: true,
                          title: Text(
                            _searchSuggestions[index],
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            _searchController.text = _searchSuggestions[index];
                            _executeSimpleSearch(_searchSuggestions[index]);
                            _hideSuggestionsOverlay();
                            FocusScope.of(context).unfocus();
                          },
                        );
                      },
                    ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(_suggestionsOverlay!);
  }

  void _showSuggestionsOverlay() {
    if (_searchQuery.trim().isNotEmpty && _searchSuggestions.isNotEmpty) {
      setState(() => _showSuggestions = true);
      _showSearchSuggestionsOverlay();
    }
  }

  void _hideSuggestionsOverlay() {
    _suggestionsOverlay?.remove();
    _suggestionsOverlay = null;
  }

  Future<void> _fetchIssuedBooks() async {
    if (!mounted) return;
    setState(() => _isBooksLoading = true);

    List<Map<String, String>> parseList(dynamic body) {
      if (body is! List) return [];
      return body
          .map<Map<String, String>>((item) {
            final m = item as Map<String, dynamic>;
            final ownerRaw =
                (m['username'] ??
                        m['user'] ??
                        m['issued_to'] ??
                        m['borrower'] ??
                        m['student'] ??
                        '')
                    .toString();
            return {
              'title': (m['book_title'] ?? '').toString(),
              'author': (m['book_author'] ?? m['auther'] ?? '').toString(),
              'issued_date': (m['issued_date'] ?? '').toString(),
              'return_date': (m['return_date'] ?? '').toString(),
              'owner': ownerRaw,
            };
          })
          .where((b) => (b['title'] ?? '').isNotEmpty)
          .toList();
    }

    Future<List<Map<String, String>>> _try(Uri url) async {
      try {
        final resp = await http.get(url).timeout(const Duration(seconds: 8));
        if (resp.statusCode != 200) return [];
        return parseList(json.decode(resp.body));
      } catch (_) {
        return [];
      }
    }

    try {
      final baseUrl = djangoBaseUrl.endsWith('/')
          ? djangoBaseUrl.substring(0, djangoBaseUrl.length - 1)
          : djangoBaseUrl;
      final uname = Uri.encodeComponent(widget.username);
      final barcode = widget.userBarcode != null
          ? Uri.encodeComponent(widget.userBarcode!)
          : '';

      // Try multiple identifiers, then global fallbacks
      final attempts = <Uri>[
        if (barcode.isNotEmpty)
          Uri.parse('$baseUrl/book-log/?barcode=$barcode&avalible=0'),
        if (barcode.isNotEmpty)
          Uri.parse('$baseUrl/book-log/?barcode=$barcode'),
        Uri.parse('$baseUrl/book-log/?username=$uname&avalible=0'),
        Uri.parse('$baseUrl/book-log/?username=$uname'),
        Uri.parse('$baseUrl/book-log/?email=$uname&avalible=0'),
        if (int.tryParse(widget.username) != null)
          Uri.parse('$baseUrl/book-log/?user_id=${widget.username}&avalible=0'),
        Uri.parse('$baseUrl/book-log/?avalible=0'),
        Uri.parse('$baseUrl/book-log/'),
      ];

      List<Map<String, String>> found = [];
      for (final url in attempts) {
        debugPrint('IssuedBooks attempt: $url');
        found = await _try(url);
        if (found.isNotEmpty) break;
      }

      if (found.isNotEmpty) {
        String norm(String s) => s.toLowerCase().trim();
        final userTok = norm(
          widget.username,
        ).split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toSet();

        List<Map<String, String>> filtered = found.where((b) {
          final owner = norm(b['owner'] ?? '');
          if (owner.isEmpty) return true; // cannot filter without owner
          final ownTok = owner
              .split(RegExp(r'\s+'))
              .where((t) => t.isNotEmpty)
              .toSet();
          final overlap = userTok.intersection(ownTok).isNotEmpty;
          return overlap ||
              owner.contains(norm(widget.username)) ||
              norm(widget.username).contains(owner);
        }).toList();

        if (filtered.isNotEmpty) {
          found = filtered;
        }
      }

      if (!mounted) return;
      setState(() {
        _issuedBooks = found;
      });
    } catch (e) {
      debugPrint('Fetch books error: $e');
      if (!mounted) return;
      setState(() {
        _issuedBooks = [];
      });
    } finally {
      if (mounted) {
        setState(() => _isBooksLoading = false);
      }
    }
  }

  // Add: unified refresh method for Home
  Future<void> _refreshHome() async {
    _hideSuggestionsOverlay();
    await _fetchIssuedBooks();
  }

  List<Map<String, String>> get _filteredBooks => _issuedBooks;

  @override
  Widget build(BuildContext context) {
    final String initial = widget.username.trim().isEmpty
        ? '?'
        : widget.username.trim()[0].toUpperCase();

    return Scaffold(
      key: _scaffoldKey,
      resizeToAvoidBottomInset: false,

      // Drawer
      drawer: Drawer(
        backgroundColor: Colors.white,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 26,
                      backgroundColor: _accent,
                      child: Text(
                        initial,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 24,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.username,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: _ink,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            "Hello! I'm using NovaLib",
                            style: TextStyle(
                              color: Colors.black54,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Menu list
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    ListTile(
                      leading: const Icon(Icons.person_outline, color: _ink),
                      title: const Text(
                        'Profile',
                        style: TextStyle(color: _ink),
                      ),
                      onTap: () => _openProfile(context),
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.notifications_outlined,
                        color: _ink,
                      ),
                      title: const Text(
                        'Notifications',
                        style: TextStyle(color: _ink),
                      ),
                      onTap: () {
                        Navigator.pushNamed(
                          context,
                          '/notifications',
                          arguments: {
                            'useAltBackground': widget.useAltBackground,
                          },
                        );
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.bookmark_border, color: _ink),
                      title: const Text(
                        'Wishlist',
                        style: TextStyle(color: _ink),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          WishListPage.route(
                            username: widget.username,
                            useAltBackground: widget.useAltBackground,
                            userBarcode: widget.userBarcode,
                          ),
                        );
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.person_outline, color: _ink),
                      title: const Text(
                        'Contacts us',
                        style: TextStyle(color: _ink),
                      ),
                      onTap: () => Navigator.pop(context),
                    ),
                    ListTile(
                      leading: const Icon(Icons.info_outline, color: _ink),
                      title: const Text(
                        'About NovaLib',
                        style: TextStyle(color: _ink),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.pushNamed(
                          context,
                          '/about_novalib',
                          arguments: {
                            'useAltBackground': widget.useAltBackground,
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.logout, color: _ink),
                title: const Text(
                  'Log out',
                  style: TextStyle(fontWeight: FontWeight.w500, color: _ink),
                ),
                onTap: () {
                  Navigator.pushReplacementNamed(context, '/login');
                },
              ),
            ],
          ),
        ),
      ),

      body: Stack(
        children: [
          // NEW: Animated two-color mixed gradient background with soft glow orbs
          const Positioned.fill(child: _AnimatedBackground()),

          // Content
          Positioned.fill(
            child: SafeArea(
              child: RefreshIndicator(
                key: _refreshKey,
                color: Colors.white,
                backgroundColor: Colors.black54,
                onRefresh: _refreshHome,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  child: Column(
                    children: [
                      // Header bar
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: 16,
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            // Lighter overlay so it competes less with cards
                            color: Colors.black.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.15),
                              width: 1,
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(
                                      Icons.menu,
                                      color: Colors.white,
                                      size: 28,
                                    ),
                                    onPressed: _openDrawer,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: SizedBox(
                                      height: 36,
                                      child: TextButton.icon(
                                        icon: const Icon(
                                          Icons.language,
                                          color: Colors.white,
                                          size: 18,
                                        ),
                                        label: const Text(
                                          'Visit Website',
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        style: ButtonStyle(
                                          backgroundColor:
                                              MaterialStateProperty.all(
                                                Colors.white.withOpacity(0.12),
                                              ),
                                          shape: MaterialStateProperty.all(
                                            RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(30),
                                            ),
                                          ),
                                          padding: MaterialStateProperty.all(
                                            const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 4,
                                            ),
                                          ),
                                          minimumSize:
                                              MaterialStateProperty.all(
                                                Size.zero,
                                              ),
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        onPressed: () => _launchWebsite(
                                          Uri.parse(
                                            'https://www.wikipedia.org/',
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    icon: const Icon(
                                      Icons.refresh,
                                      color: Colors.white,
                                      size: 24,
                                    ),
                                    onPressed: () async {
                                      _refreshKey.currentState?.show();
                                      await _refreshHome();
                                    },
                                  ),
                                  IconButton(
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    icon: const Icon(
                                      Icons.notifications,
                                      color: Colors.white,
                                      size: 24,
                                    ),
                                    onPressed: () {
                                      Navigator.pushNamed(
                                        context,
                                        '/notifications',
                                        arguments: {
                                          'useAltBackground':
                                              widget.useAltBackground,
                                        },
                                      );
                                    },
                                  ),
                                  IconButton(
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                      minWidth: 10,
                                    ),
                                    icon: const Icon(
                                      Icons.logout,
                                      color: Colors.white,
                                      size: 24,
                                    ),
                                    onPressed: () {
                                      Navigator.pushReplacementNamed(
                                        context,
                                        '/login',
                                      );
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              // Greeting row
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 20,
                                      backgroundColor: _accent,
                                      child: Text(
                                        initial,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 18,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        'Hello, ${widget.username}! 😄',
                                        style: const TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Search with dropdown suggestions (overlay-based)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                        child: CompositedTransformTarget(
                          link: _layerLink,
                          child: TextField(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 16.0,
                              fontWeight: FontWeight.w600,
                            ),
                            cursorColor: _accent,
                            cursorWidth: 2.0,
                            decoration: InputDecoration(
                              hintText: 'Search books...',
                              hintStyle: const TextStyle(color: _muted),
                              filled: true,
                              fillColor: Colors.white.withOpacity(0.96),
                              prefixIcon: _isSearchLoading
                                  ? const Padding(
                                      padding: EdgeInsets.all(10),
                                      child: SizedBox(
                                        height: 18,
                                        width: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: _accent,
                                        ),
                                      ),
                                    )
                                  : const Icon(
                                      Icons.search,
                                      color: _muted,
                                      size: 22,
                                    ),
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 12,
                                horizontal: 12,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(28),
                                borderSide: const BorderSide(
                                  color: Colors.transparent,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(28),
                                borderSide: BorderSide(
                                  color: Colors.black.withOpacity(0.06),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(28),
                                borderSide: const BorderSide(
                                  color: _accent,
                                  width: 1.2,
                                ),
                              ),
                            ),
                            onChanged: (value) {
                              _onSearchChanged(value);
                              if (value.trim().length > 1) {
                                _showSuggestionsOverlay();
                              } else {
                                _hideSuggestionsOverlay();
                              }
                            },
                            onSubmitted: (query) {
                              if (query.trim().isEmpty) return;
                              _debounce?.cancel();
                              _executeSimpleSearch(query);
                              _hideSuggestionsOverlay();
                            },
                            onTap: () {
                              if (_searchController.text.trim().isNotEmpty) {
                                _showSuggestionsOverlay();
                              }
                            },
                          ),
                        ),
                      ),
                      // For you
                      const SizedBox(height: 12),
                      const _SectionHeader(text: 'For you'),
                      const SizedBox(height: 18),
                      // Three boxes (pastel)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // Issued Books
                            Expanded(
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => IssuedBooksPage(
                                          username: widget.username,
                                          userBarcode: widget.userBarcode,
                                        ),
                                      ),
                                    );
                                  },
                                  child: Container(
                                    height: 90,
                                    decoration: _frostBox(),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        if (_isBooksLoading)
                                          const SizedBox(
                                            height: 26,
                                            width: 26,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: _accent,
                                            ),
                                          )
                                        else
                                          Text(
                                            '${_issuedBooks.length}',
                                            style: const TextStyle(
                                              color: _ink,
                                              fontWeight: FontWeight.w800,
                                              fontSize: 28,
                                            ),
                                          ),
                                        const SizedBox(height: 4),
                                        const Text(
                                          'Issued Books',
                                          style: TextStyle(
                                            color: _muted,
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // Wishlist
                            Expanded(
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      WishListPage.route(
                                        username: widget.username,
                                        useAltBackground:
                                            widget.useAltBackground,
                                        userBarcode: widget.userBarcode,
                                      ),
                                    );
                                  },
                                  child: Container(
                                    margin: const EdgeInsets.only(left: 10),
                                    height: 90,
                                    decoration: _frostBox(),
                                    child: const Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          '5',
                                          style: TextStyle(
                                            color: _ink,
                                            fontWeight: FontWeight.w800,
                                            fontSize: 28,
                                          ),
                                        ),
                                        SizedBox(height: 4),
                                        Text(
                                          'Wishlist',
                                          style: TextStyle(
                                            color: _muted,
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // Pay Fine
                            Expanded(
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => PayFinePage(
                                          username: widget.username,
                                        ),
                                      ),
                                    );
                                  },
                                  child: Container(
                                    margin: const EdgeInsets.only(left: 10),
                                    height: 90,
                                    decoration: _frostBox(),
                                    child: const Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          '₹12',
                                          style: TextStyle(
                                            color: _ink,
                                            fontWeight: FontWeight.w800,
                                            fontSize: 28,
                                          ),
                                        ),
                                        SizedBox(height: 4),
                                        Text(
                                          'Due Fine',
                                          style: TextStyle(
                                            color: _muted,
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Issued Books section
                      const SizedBox(height: 18),
                      const _SectionHeader(text: 'Issued Books'),
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Container(
                          decoration: _frostItem(),
                          padding: const EdgeInsets.symmetric(
                            vertical: 10,
                            horizontal: 8,
                          ),
                          child: _isBooksLoading
                              ? const Center(
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(vertical: 24),
                                    child: CircularProgressIndicator(),
                                  ),
                                )
                              : Column(
                                  children: _filteredBooks.isEmpty
                                      ? const [
                                          Text(
                                            'No books found.',
                                            style: TextStyle(
                                              color: _ink,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ]
                                      : List.generate(
                                          _filteredBooks.length,
                                          (i) => Container(
                                            margin: const EdgeInsets.only(
                                              bottom: 12,
                                            ),
                                            decoration: _frostRow(),
                                            child: ListTile(
                                              leading: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    gradient:
                                                        const LinearGradient(
                                                          colors: [
                                                            Color(0xFF7C3AED),
                                                            _accent,
                                                          ],
                                                          begin:
                                                              Alignment.topLeft,
                                                          end: Alignment
                                                              .bottomRight,
                                                        ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          8,
                                                        ),
                                                  ),
                                                  width: 50,
                                                  height: 50,
                                                  child: const Icon(
                                                    Icons.menu_book_rounded,
                                                    color: Colors.white,
                                                    size: 26,
                                                  ),
                                                ),
                                              ),
                                              title: Text(
                                                _filteredBooks[i]['title']!,
                                                style: const TextStyle(
                                                  color: _ink,
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 16,
                                                ),
                                              ),
                                              subtitle: Text(
                                                _filteredBooks[i]['author']!,
                                                style: const TextStyle(
                                                  color: _muted,
                                                  fontSize: 13,
                                                ),
                                              ),
                                              trailing: const Icon(
                                                Icons.arrow_forward_ios_rounded,
                                                color: _muted,
                                                size: 18,
                                              ),
                                            ),
                                          ),
                                        ),
                                ),
                        ),
                      ),
                      // Recommendations
                      const SizedBox(height: 18),
                      const _SectionHeader(text: 'Book recommended for you'),
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            Expanded(
                              child: Container(
                                height: 200,
                                decoration: _frostCard(),
                                child: _bookIcon(),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Container(
                                height: 200,
                                decoration: _frostCard(),
                                child: _bookIcon(),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            Expanded(
                              child: Container(
                                height: 200,
                                decoration: _frostCard(),
                                child: _bookIcon(),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Container(
                                height: 200,
                                decoration: _frostCard(),
                                child: _bookIcon(),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 80),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Animated gradient background with soft glow “orbs”
class _AnimatedBackground extends StatefulWidget {
  const _AnimatedBackground({Key? key}) : super(key: key);

  @override
  State<_AnimatedBackground> createState() => _AnimatedBackgroundState();
}

class _AnimatedBackgroundState extends State<_AnimatedBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _t;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 14))
      ..repeat(reverse: true);
    _t = CurvedAnimation(parent: _c, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (_, __) {
        // Interpolate colors and alignment to add subtle motion
        final Color c1 = Color.lerp(_bgA1, _bgB1, _t.value)!;
        final Color c2 = Color.lerp(_bgA2, _bgB2, _t.value)!;
        final Alignment aBegin = Alignment.lerp(
          Alignment.topLeft,
          Alignment.topRight,
          _t.value,
        )!;
        final Alignment aEnd = Alignment.lerp(
          Alignment.bottomRight,
          Alignment.bottomLeft,
          _t.value,
        )!;

        return Stack(
          children: [
            // Main animated gradient
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [c1, c2],
                    begin: aBegin,
                    end: aEnd,
                  ),
                ),
              ),
            ),
            // Soft glow orbs (radial gradients)
            // Top-right orb
            Positioned(
              right: -60,
              top: -40,
              child: _orb(color: Colors.white.withOpacity(0.20), size: 220),
            ),
            // Bottom-left orb
            Positioned(
              left: -80,
              bottom: -60,
              child: _orb(color: Colors.white.withOpacity(0.14), size: 260),
            ),
          ],
        );
      },
    );
  }

  Widget _orb({required Color color, required double size}) {
    return IgnorePointer(
      ignoring: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, Colors.transparent],
            stops: const [0.0, 1.0],
          ),
        ),
      ),
    );
  }
}

// Section header
class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader({Key? key, required this.text}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

// Warmer pastel tokens (blend better with warm gradient)
const _blushHi = Color(0xFFFFF3F7); // warm rose
const _blushLo = Color(0xFFFFE9F2);
const _blushBd = Color(0xFFFFD6E4);

const _mintHi = Color(0xFFF1FBF5); // soft mint
const _mintLo = Color(0xFFE8F7EE);
const _mintBd = Color(0xFFD1EFDD);

const _pearlHi = Color(0xFFF9F6FF); // neutral pearl
const _pearlLo = Color(0xFFF3EEFF);
const _pearlBd = Color(0xFFE3D9FF);

// Stat cards (“For you”) — neutral pearl so numbers pop; light shadow
BoxDecoration _frostBox() => BoxDecoration(
  gradient: const LinearGradient(
    colors: [_pearlHi, _pearlLo],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  ),
  borderRadius: BorderRadius.circular(16),
  border: Border.all(color: _pearlBd, width: 1),
  boxShadow: const [
    BoxShadow(color: Color(0x16000000), blurRadius: 14, offset: Offset(0, 8)),
  ],
);

// Issued Books container — blush (warmer)
BoxDecoration _frostItem() => BoxDecoration(
  gradient: const LinearGradient(
    colors: [_blushHi, _blushLo],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  ),
  borderRadius: BorderRadius.circular(16),
  border: Border.all(color: _blushBd, width: 1),
  boxShadow: const [
    BoxShadow(color: Color(0x14000000), blurRadius: 16, offset: Offset(0, 8)),
  ],
);

// Issued Books rows — mint (fresh), very light shadow
BoxDecoration _frostRow() => BoxDecoration(
  gradient: const LinearGradient(
    colors: [_mintHi, _mintLo],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  ),
  borderRadius: BorderRadius.circular(14),
  border: Border.all(color: _mintBd, width: 1),
  boxShadow: const [
    BoxShadow(color: Color(0x12000000), blurRadius: 10, offset: Offset(0, 5)),
  ],
);

// Recommendation cards — pearl to match stats
BoxDecoration _frostCard() => BoxDecoration(
  gradient: const LinearGradient(
    colors: [_pearlHi, _pearlLo],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  ),
  borderRadius: BorderRadius.circular(16),
  border: Border.all(color: _pearlBd, width: 1),
  boxShadow: const [
    BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 6)),
  ],
);

// Icon color on pastel surfaces
Widget _bookIcon() =>
    const Center(child: Icon(Icons.book_outlined, color: _muted, size: 36));
