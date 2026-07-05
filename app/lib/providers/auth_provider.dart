import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../services/auth_service.dart';

class AuthProvider extends ChangeNotifier {
  AuthProvider() {
    unawaited(_bootstrap());
  }

  User? _user;
  String? _authToken;

  User? get user => _user;
  bool get isAuthenticated => _user != null;
  String? get authToken => _authToken;

  Future<void> _bootstrap() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
      _user = FirebaseAuth.instance.currentUser;
      FirebaseAuth.instance.authStateChanges().listen((user) {
        _user = user;
        notifyListeners();
      });
    } catch (_) {
      _user = null;
    }
  }

  Future<bool> signInWithGoogle() async {
    try {
      final result = await AuthService.instance.signInWithGoogleMobile();
      if (result == null) return false;

      _user = FirebaseAuth.instance.currentUser;
      _authToken = await AuthService.instance.getIdToken();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> signOut() async {
    await AuthService.instance.signOut();
    _authToken = null;
    notifyListeners();
  }
}
