// swift-tools-version: 5.9
// Package.swift — Swift Package Manager dependencies for ParentGuard iOS
//
// How to use:
//   1. Open Xcode → File → Add Package Dependencies
//   2. Add the Firebase iOS SDK: https://github.com/firebase/firebase-ios-sdk
//   3. Select: FirebaseAuth, FirebaseFirestore, FirebaseMessaging
//   4. FamilyControls, DeviceActivity, ManagedSettings are Apple system frameworks
//      — add them in your target's "Frameworks and Libraries" in Xcode, not here.
//
// This file documents dependencies; Xcode manages the actual resolution.

import PackageDescription

let package = Package(
    name: "ParentGuard",
    platforms: [
        .iOS(.v16)   // FamilyControls DeviceActivityMonitor requires iOS 16+
    ],
    products: [
        .library(name: "ParentGuard", targets: ["ParentGuard"])
    ],
    dependencies: [
        // Firebase iOS SDK — add via Xcode Package Dependencies UI
        // URL: https://github.com/firebase/firebase-ios-sdk
        // Version: 10.20.0 or later
        .package(
            url: "https://github.com/firebase/firebase-ios-sdk.git",
            from: "10.20.0"
        ),
    ],
    targets: [
        .target(
            name: "ParentGuard",
            dependencies: [
                .product(name: "FirebaseAuth",      package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseMessaging", package: "firebase-ios-sdk"),
            ]
        ),
        // DeviceActivityExtension is a SEPARATE Xcode target (App Extension).
        // It cannot be added via SPM; create it in Xcode:
        //   File → New → Target → Device Activity Monitor Extension
        .target(name: "DeviceActivityExtension"),
    ]
)
