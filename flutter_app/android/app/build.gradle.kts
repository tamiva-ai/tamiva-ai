import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")

if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.tamiva.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.tamiva.app"
        // Pinned at API 21 (Android 5.0) so the existing release's user base can
        // upgrade. Flutter 3.44.6's default is 24, but the previously uploaded
        // release supports down to 21 — Play Console refused the rollout because
        // the new AAB would lock out users on Android 5/5.1/6.
        // Bump this back to flutter.minSdkVersion (or higher) once every existing
        // user is on a recent version.
        minSdk = 21
        targetSdk = flutter.targetSdkVersion
        // versionCode and versionName are supplied by the CI workflow via
        // `flutter build appbundle --build-name=<X> --build-number=<Y>`,
        // which derive X/Y from the highest existing vN.M.K git tag (see
        // .github/scripts/next-version.sh). DO NOT pin these here — that
        // would override the CLI flags and re-introduce Play Console's
        // "version code already used" rejection.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                // Resolve from the *root* Android project (flutter_app/android/) so the
                // relative path in key.properties works. The keystore lives next to
                // key.properties at flutter_app/android/tamiva-upload.jks.
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        getByName("debug") {
        }

        getByName("release") {
            signingConfig = signingConfigs.getByName("release")

            // IMPORTANT: Do NOT set `isShrinkResources` here.
            // On AGP 8.9.x, simply mentioning `isShrinkResources = ...`
            // forces AGP to evaluate the resource-shrinker path, which then
            // requires `isMinifyEnabled = true` and trips:
            //   "Removing unused resources requires unused code shrinking to be turned on."
            // Leaving it unset keeps resource shrinking disabled.

            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}