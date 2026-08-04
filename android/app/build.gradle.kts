import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: without a *consistent* signature across builds, every
// CI-built APK gets a different random debug key (a fresh debug.keystore
// is auto-generated per machine/runner), and Android refuses to install
// an "update" whose signature doesn't match what's already installed -
// forcing an uninstall before every single reinstall. key.properties
// (gitignored - a real signing key must never be committed) points at a
// real, stable keystore for this; CI writes both dynamically from
// secrets (see .github/workflows/release.yml) before every build. Falls
// back to the debug key when neither is present, so plain local
// `flutter run --release` still works out of the box.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "com.bteuile.moneymanager.money_manager"
    // flutter.compileSdkVersion currently resolves lower than plugins in
    // this project require (flutter_plugin_android_lifecycle needs 36+).
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (see its README) - without
        // this, :app:checkReleaseAarMetadata fails the release build outright.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.bteuile.moneymanager.money_manager"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // No key.properties (a plain local checkout without the
                // real keystore) - fall back to the debug key so
                // `flutter run --release` still just works.
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Version per flutter_local_notifications' own README - keep these two
    // in step if that package is ever upgraded.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
