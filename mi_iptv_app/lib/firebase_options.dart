import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        return web;
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCdezgxIJsdnEXyvZaeazYYpHHbzcHm9Xs',
    appId: '1:1056187378484:web:18fd0ec0a86c7c9af19361',
    messagingSenderId: '1056187378484',
    projectId: 'ameycartv',
    authDomain: 'ameycartv.firebaseapp.com',
    storageBucket: 'ameycartv.firebasestorage.app',
  );

  // En Android ya se lee automáticamente de google-services.json
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyCdezgxIJsdnEXyvZaeazYYpHHbzcHm9Xs',
    appId: '1:1056187378484:android:db9892c4c28259c2f19361',
    messagingSenderId: '1056187378484',
    projectId: 'ameycartv',
    storageBucket: 'ameycartv.firebasestorage.app',
  );
}