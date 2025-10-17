import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:ui'; // for ImageFilter.blur
import 'config.dart'; // use shared config instead of importing main.dart
import 'dart:async'; // Add this import for Timer
import 'WishList_page/wishlist.dart';
import 'package:mobile_scanner/mobile_scanner.dart'; // already imported

class HomePage extends StatefulWidget {
  final bool useAltBackground;
  final String username;

  const HomePage({
    Key? key,
    required this.useAltBackground,
    required this.username,
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
      // Try default mode
      bool launched = await launchUrl(url, mode: LaunchMode.platformDefault);
      if (!launched) {
        // Fallback to external browser
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
                backgroundColor: const Color(0xFF5B6BFF),
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
    // Hide dropdown when focus leaves the search field
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

    // Cancel any previous debounce timer
    if (_debounce?.isActive ?? false) _debounce!.cancel();

    if (query.trim().isEmpty) {
      _hideSuggestionsOverlay();
      return;
    }

    // Use a shorter debounce for suggestions (300ms)
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;

      // Fetch suggestions as user types
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

      // Use the suggestions endpoint - modify this to match your API
      final url = Uri.parse(
        '$baseUrl/book-suggestions/?search=${Uri.encodeComponent(query)}',
      );

      final response = await http
          .get(url)
          .timeout(const Duration(seconds: 2)); // Short timeout for suggestions

      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);

        // Extract book titles for suggestions
        setState(() {
          _searchSuggestions = data
              .map<String>((item) => item['book_title']?.toString() ?? '')
              .where((title) => title.isNotEmpty)
              .toList();

          // If no suggestions endpoint available, fallback to titles from main search
          if (_searchSuggestions.isEmpty) {
            // Try to extract titles from the book-log endpoint as fallback
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
        // Fallback to the main endpoint if suggestions endpoint fails
        _fetchFallbackSuggestions(query);
      }
    } catch (e) {
      debugPrint('Fetch suggestions error: $e');
      // Fallback to the main endpoint if suggestions endpoint fails
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

        // Extract book titles for suggestions
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
        setState(() {
          _isSearchLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Fallback suggestions error: $e');
      if (mounted) {
        setState(() {
          _isSearchLoading = false;
        });
      }
    }
  }

  // A much simpler search implementation
  Future<void> _executeSimpleSearch(String query) async {
    try {
      // Only show search loader; do not touch issued-books loader
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

        // Update only search results; do NOT modify _issuedBooks
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
        setState(() {
          _isSearchLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error searching books: ${response.statusCode}'),
          ),
        );
      }
    } catch (e) {
      debugPrint('Search error: $e');
      if (!mounted) return;
      setState(() {
        _isSearchLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Search error: Network or server issue')),
      );
    }
  }

  // Add new method to build search suggestions overlay (frosted theme)
  void _showSearchSuggestionsOverlay() {
    _hideSuggestionsOverlay(); // Remove any existing overlay

    final overlay = Overlay.of(context);

    _suggestionsOverlay = OverlayEntry(
      builder: (context) => Positioned(
        width: MediaQuery.of(context).size.width - 32, // Match search bar width
        top: MediaQuery.of(context).padding.top + 190, // below header + search
        left: 16,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0.0, 30.0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.white.withOpacity(0.12),
                      Colors.white.withOpacity(0.06),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.25),
                    width: 1.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.25),
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
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
                              color: Colors.white70,
                              size: 20,
                            ),
                            minLeadingWidth: 20,
                            dense: true,
                            title: Text(
                              _searchSuggestions[index],
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () {
                              _searchController.text =
                                  _searchSuggestions[index];
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
      ),
    );

    overlay.insert(_suggestionsOverlay!);
  }

  // Update the search suggestions functionality
  void _showSuggestionsOverlay() {
    if (_searchQuery.trim().isNotEmpty && _searchSuggestions.isNotEmpty) {
      setState(() {
        _showSuggestions = true;
      });
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

    // Parse list and extract possible owner and author fields
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

      // Try multiple identifiers, then global fallbacks
      final attempts = <Uri>[
        // Prefer issued items
        Uri.parse('$baseUrl/book-log/?username=$uname&avalible=0'),
        Uri.parse('$baseUrl/book-log/?username=$uname'),
        Uri.parse('$baseUrl/book-log/?barcode=$uname&avalible=0'),
        Uri.parse('$baseUrl/book-log/?email=$uname&avalible=0'),
        if (int.tryParse(widget.username) != null)
          Uri.parse('$baseUrl/book-log/?user_id=${widget.username}&avalible=0'),
        // Global fallbacks if backend ignores identifiers
        Uri.parse('$baseUrl/book-log/?avalible=0'),
        Uri.parse('$baseUrl/book-log/'),
      ];

      List<Map<String, String>> found = [];
      for (final url in attempts) {
        debugPrint('IssuedBooks attempt: $url');
        found = await _try(url);
        if (found.isNotEmpty) break;
      }

      // Client-side filter: match owner tokens with username tokens if owner present
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
          // Keep if any token overlaps or direct contains either way
          final overlap = userTok.intersection(ownTok).isNotEmpty;
          return overlap ||
              owner.contains(norm(widget.username)) ||
              norm(widget.username).contains(owner);
        }).toList();

        // If filtering removed everything (owner not matching tokens), fall back to original result
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

  // Keep original alias so Issued Books list continues to use current data
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
                      backgroundColor: const Color(0xFF5B6BFF),
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
                      leading: const Icon(Icons.person_outline),
                      title: const Text('Profile'),
                      onTap: () => _openProfile(context),
                    ),
                    ListTile(
                      leading: const Icon(Icons.notifications_outlined),
                      title: const Text('Notifications'),
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
                      leading: const Icon(Icons.bookmark_border),
                      title: const Text('Wishlist'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          WishListPage.route(
                            username: widget.username,
                            useAltBackground:
                                widget.useAltBackground, // pass flag
                          ),
                        );
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const Text('Contacts us'),
                      onTap: () => Navigator.pop(context),
                    ),
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('About NovaLib'),
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
                leading: const Icon(Icons.logout, color: Colors.black),
                title: const Text(
                  'Log out',
                  style: TextStyle(fontWeight: FontWeight.w500),
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
          // Background
          Positioned.fill(
            child: Image.asset(
              widget.useAltBackground
                  ? 'assets/background2.jpg'
                  : 'assets/background1.jpg',
              key: ValueKey(widget.useAltBackground),
              fit: BoxFit.cover,
            ),
          ),
          // Gradient overlay
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.black.withOpacity(0.15),
                    Colors.black.withOpacity(0.35),
                    Colors.black.withOpacity(0.6),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ),
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
                      // Header bar (frosted glass)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: 16,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.white.withOpacity(0.12),
                                    Colors.white.withOpacity(0.06),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.25),
                                  width: 1,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.25),
                                    blurRadius: 16,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
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
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            style: ButtonStyle(
                                              backgroundColor:
                                                  MaterialStateProperty.all(
                                                    Colors.white.withOpacity(
                                                      0.12,
                                                    ),
                                                  ),
                                              shape: MaterialStateProperty.all(
                                                RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(30),
                                                ),
                                              ),
                                              side: MaterialStateProperty.all(
                                                BorderSide(
                                                  color: Colors.white
                                                      .withOpacity(0.25),
                                                ),
                                              ),
                                              padding:
                                                  MaterialStateProperty.all(
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
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
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
                                          backgroundColor: const Color(
                                            0xFF5B6BFF,
                                          ),
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
                        ),
                      ),
                      // Search with dropdown suggestions (overlay-based, frosted field)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                        child: CompositedTransformTarget(
                          link: _layerLink,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(28),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                              child: TextField(
                                controller: _searchController,
                                focusNode: _searchFocusNode,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16.0,
                                  fontWeight: FontWeight.w600,
                                ),
                                cursorColor: Colors.white,
                                cursorWidth: 2.0,
                                decoration: InputDecoration(
                                  hintText: 'Search books...',
                                  hintStyle: const TextStyle(
                                    color: Colors.white70,
                                  ),
                                  filled: true,
                                  fillColor: Colors.white.withOpacity(0.10),
                                  prefixIcon: _isSearchLoading
                                      ? Container(
                                          padding: const EdgeInsets.all(10),
                                          width: 12,
                                          height: 12,
                                          child:
                                              const CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white70,
                                              ),
                                        )
                                      : const Icon(
                                          Icons.search,
                                          color: Colors.white70,
                                          size: 22,
                                        ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                    horizontal: 12,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(28),
                                    borderSide: BorderSide(
                                      color: Colors.white.withOpacity(0.25),
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(28),
                                    borderSide: BorderSide(
                                      color: Colors.white.withOpacity(0.20),
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(28),
                                    borderSide: const BorderSide(
                                      color: Colors.white,
                                      width: 1,
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
                                  if (_searchController.text
                                      .trim()
                                      .isNotEmpty) {
                                    _showSuggestionsOverlay();
                                  }
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                      // For you
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'For you',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      // Three boxes (frosted)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Container(
                                height: 90,
                                decoration: _glassBoxDecoration(),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (_isBooksLoading)
                                      const SizedBox(
                                        height: 26,
                                        width: 26,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    else
                                      const SizedBox(height: 0),
                                    Text(
                                      _isBooksLoading
                                          ? ''
                                          : '${_issuedBooks.length}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 32,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Issued Books',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Expanded(
                              child: Container(
                                margin: const EdgeInsets.only(left: 10),
                                height: 90,
                                decoration: _glassBoxDecoration(),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: const [
                                    Text(
                                      '5',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 32,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      'Wishlist',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Expanded(
                              child: Container(
                                margin: const EdgeInsets.only(left: 10),
                                height: 90,
                                decoration: _glassBoxDecoration(),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: const [
                                    Text(
                                      '₹12',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 32,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      'Due Fine',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Issued Books section
                      const SizedBox(height: 18),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Issued Books',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Container(
                          decoration: _glassItemDecoration(), // frosted box
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
                                              color: Color.fromARGB(
                                                200,
                                                255,
                                                255,
                                                255,
                                              ),
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
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                colors: [
                                                  Colors.white.withOpacity(
                                                    0.10,
                                                  ),
                                                  Colors.white.withOpacity(
                                                    0.06,
                                                  ),
                                                ],
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              border: Border.all(
                                                color: Colors.white.withOpacity(
                                                  0.22,
                                                ),
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black
                                                      .withOpacity(0.20),
                                                  blurRadius: 10,
                                                  offset: const Offset(0, 6),
                                                ),
                                              ],
                                            ),
                                            child: ListTile(
                                              leading: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                child: Container(
                                                  color: const Color(
                                                    0xFF5B6BFF,
                                                  ),
                                                  width: 50,
                                                  height: 50,
                                                  child: const Icon(
                                                    Icons.menu_book_rounded,
                                                    color: Colors.white,
                                                    size: 28,
                                                  ),
                                                ),
                                              ),
                                              title: Text(
                                                _filteredBooks[i]['title']!,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 16,
                                                ),
                                              ),
                                              subtitle: Text(
                                                _filteredBooks[i]['author']!,
                                                style: TextStyle(
                                                  color: Colors.white
                                                      .withOpacity(0.8),
                                                  fontSize: 13,
                                                ),
                                              ),
                                              trailing: Icon(
                                                Icons.arrow_forward_ios_rounded,
                                                color: Colors.white.withOpacity(
                                                  0.6,
                                                ),
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
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Book recommended for you',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(
                                    sigmaX: 12,
                                    sigmaY: 12,
                                  ),
                                  child: Container(
                                    height: 200,
                                    decoration: _glassCardDecoration(),
                                    child: _bookIcon(),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(
                                    sigmaX: 12,
                                    sigmaY: 12,
                                  ),
                                  child: Container(
                                    height: 200,
                                    decoration: _glassCardDecoration(),
                                    child: _bookIcon(),
                                  ),
                                ),
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
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(
                                    sigmaX: 12,
                                    sigmaY: 12,
                                  ),
                                  child: Container(
                                    height: 200,
                                    decoration: _glassCardDecoration(),
                                    child: _bookIcon(),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(
                                    sigmaX: 12,
                                    sigmaY: 12,
                                  ),
                                  child: Container(
                                    height: 200,
                                    decoration: _glassCardDecoration(),
                                    child: _bookIcon(),
                                  ),
                                ),
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

// Reusable decorations (frosted theme)
BoxDecoration _glassBoxDecoration() => BoxDecoration(
  gradient: LinearGradient(
    colors: [Colors.white.withOpacity(0.12), Colors.white.withOpacity(0.06)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  ),
  borderRadius: BorderRadius.circular(16),
  border: Border.all(color: Colors.white.withOpacity(0.25), width: 1),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withOpacity(0.25),
      blurRadius: 12,
      offset: const Offset(0, 6),
    ),
  ],
);

BoxDecoration _glassItemDecoration() => BoxDecoration(
  gradient: LinearGradient(
    colors: [Colors.white.withOpacity(0.10), Colors.white.withOpacity(0.06)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  ),
  borderRadius: BorderRadius.circular(14),
  border: Border.all(color: Colors.white.withOpacity(0.22), width: 1),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withOpacity(0.22),
      blurRadius: 10,
      offset: const Offset(0, 6),
    ),
  ],
);

BoxDecoration _glassCardDecoration() => BoxDecoration(
  gradient: LinearGradient(
    colors: [Colors.white.withOpacity(0.10), Colors.white.withOpacity(0.06)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  ),
  borderRadius: BorderRadius.circular(16),
  border: Border.all(color: Colors.white.withOpacity(0.22), width: 1),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withOpacity(0.22),
      blurRadius: 12,
      offset: const Offset(0, 8),
    ),
  ],
);

Widget _bookIcon() => Center(
  child: Icon(
    Icons.book_outlined,
    color: Colors.white.withOpacity(0.8),
    size: 36,
  ),
);

// Replace only the _IssueBarcodeScannerScreen with the version below.
// Keep all of your existing imports, network calls, and UI intact.
// Replace only the _IssueBarcodeScannerScreen with the version below.
// Keep all of your existing imports, network calls, and UI intact.

class _IssueBarcodeScannerScreen extends StatefulWidget {
  const _IssueBarcodeScannerScreen({Key? key}) : super(key: key);

  @override
  State<_IssueBarcodeScannerScreen> createState() =>
      _IssueBarcodeScannerScreenState();
}

class _IssueBarcodeScannerScreenState extends State<_IssueBarcodeScannerScreen>
    with WidgetsBindingObserver {
  // mobile_scanner ^7.x controller
  final MobileScannerController _controller = MobileScannerController(
    facing: CameraFacing.back,
    torchEnabled: false,
    // helps avoid rapid double-detections and buffer churn
    detectionTimeoutMs: 800,
  );

  bool _handled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  // Make sure we release/reacquire the camera surface properly
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (!mounted) return;
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // Stop the camera when the app is not visible/active
        await _controller.stop();
        break;
      case AppLifecycleState.resumed:
        // Clear any handled flag so we can scan again after resume
        _handled = false;
        await _controller.start();
        break;
      case AppLifecycleState.detached:
        break;
      default:
        // Fallback for any future/unknown states
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan Book Barcode'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Torch',
            onPressed: () => _controller.toggleTorch(),
            icon: const Icon(Icons.flashlight_on_outlined),
            color: Colors.white70,
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            // v7 uses BarcodeCapture
            onDetect: (BarcodeCapture capture) {
              if (_handled) return;
              final barcodes = capture.barcodes;
              if (barcodes.isEmpty) return;
              final code = barcodes.first.rawValue;
              if (code != null && code.isNotEmpty) {
                _handled = true;
                Navigator.of(context).pop(code);
              }
            },
          ),
          // Lightweight overlay (no additional blur here to reduce GPU load)
          Center(
            child: Container(
              width: MediaQuery.of(context).size.width * 0.72,
              height: MediaQuery.of(context).size.width * 0.72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Colors.white.withOpacity(0.25),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.white.withOpacity(0.15),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
