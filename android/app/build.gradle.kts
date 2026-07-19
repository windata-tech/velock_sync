plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun buildConfigString(value: String): String =
    "\"${value.replace("\\", "\\\\").replace("\"", "\\\"")}\""

val velockExchangeAuthority = providers.gradleProperty("VELOCK_EXCHANGE_AUTHORITY").orNull.orEmpty()
val velockCompanionPackage = providers.gradleProperty("VELOCK_COMPANION_PACKAGE").orNull.orEmpty()
val velockCompanionCertSha256 = providers.gradleProperty("VELOCK_COMPANION_CERT_SHA256").orNull.orEmpty()
val releaseStoreFile = providers.gradleProperty("RELEASE_STORE_FILE").orNull.orEmpty()
val releaseStorePassword = providers.gradleProperty("RELEASE_STORE_PASSWORD").orNull.orEmpty()
val releaseKeyAlias = providers.gradleProperty("RELEASE_KEY_ALIAS").orNull.orEmpty()
val releaseKeyPassword = providers.gradleProperty("RELEASE_KEY_PASSWORD").orNull.orEmpty()
val hasReleaseSigning = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all(String::isNotEmpty)

android {
    namespace = "tech.windata.velock.sync.velock_sync"
    compileSdk = flutter.compileSdkVersion
    // Flutter currently resolves to a locally corrupted 28.2 install. Use the
    // complete stable NDK already available in the development environment.
    ndkVersion = "28.0.13004108"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "tech.windata.velock.sync.velock_sync"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Android Velock exchange is disabled in ordinary builds. A release
        // integration must explicitly provide all three non-secret trust
        // identifiers and is checked again at runtime before any IPC call.
        buildConfigField(
            "String",
            "VELOCK_EXCHANGE_AUTHORITY",
            buildConfigString(velockExchangeAuthority),
        )
        buildConfigField(
            "String",
            "VELOCK_COMPANION_PACKAGE",
            buildConfigString(velockCompanionPackage),
        )
        buildConfigField(
            "String",
            "VELOCK_COMPANION_CERT_SHA256",
            buildConfigString(velockCompanionCertSha256),
        )
        manifestPlaceholders["velockExchangeAuthority"] =
            velockExchangeAuthority.ifEmpty { "tech.windata.velock.exchange.disabled" }
    }

    buildFeatures {
        buildConfig = true
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("officialRelease") {
                storeFile = file(releaseStoreFile)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Release packages must never silently fall back to the debug key.
            // AGP rejects an unsigned release when official signing properties
            // are absent, which is the intended safe default.
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("officialRelease")
            }
        }
    }
}

dependencies {
    implementation("androidx.documentfile:documentfile:1.0.1")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

flutter {
    source = "../.."
}

val verifyOfficialReleaseSigning by tasks.registering {
    group = "verification"
    description = "Rejects release assembly without an official signing key."
    doLast {
        check(hasReleaseSigning) {
            "Release signing requires RELEASE_STORE_FILE, RELEASE_STORE_PASSWORD, " +
                "RELEASE_KEY_ALIAS, and RELEASE_KEY_PASSWORD."
        }
        check(file(releaseStoreFile).isFile) {
            "RELEASE_STORE_FILE does not reference a readable keystore."
        }
    }
}

tasks.configureEach {
    if (name == "assembleRelease" || name == "bundleRelease") {
        dependsOn(verifyOfficialReleaseSigning)
    }
}
