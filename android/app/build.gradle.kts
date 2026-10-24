plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.mawena.fluluks"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.mawena.fluluks"
        minSdk = 26
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
        externalNativeBuild {
            cmake {
                arguments += listOf("-DFL_TESTS=OFF", "-DFL_SANITIZE=OFF")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("../../native/CMakeLists.txt")
            version = "3.22.1"
        }
    }


    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // Manifestes OSGi en double (JSch, Bouncy Castle, jspecify) : inutiles sur Android.
    packaging {
        resources {
            excludes += "META-INF/versions/*/OSGI-INF/MANIFEST.MF"
        }
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.media3:media3-exoplayer:1.11.1")
    implementation("androidx.media3:media3-ui:1.11.1")
    implementation("androidx.media3:media3-session:1.11.1")
    implementation("commons-net:commons-net:3.13.0")
    // SFTP : JSch (fork mwiede) ; Bouncy Castle pour Ed25519 et Curve25519 sur Android.
    implementation("com.github.mwiede:jsch:2.28.8")
    implementation("org.bouncycastle:bcprov-jdk18on:1.86")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.apache.sshd:sshd-core:2.20.0")
    testImplementation("org.apache.sshd:sshd-sftp:2.20.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    testImplementation("org.json:json:20240303")
    testImplementation("org.apache.ftpserver:ftpserver-core:1.2.1")
    androidTestImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:rules:1.6.1")
}

flutter {
    source = "../.."
}

// integration_test (Flutter, en dépendance de développement) tire androidx.test 1.2.x dans le classpath de debug ; la
// résolution cohérente l'imposerait alors aux essais instrumentés (runner 1.6.2) : on aligne sur leurs versions.
configurations.configureEach {
    resolutionStrategy.force("androidx.test:runner:1.6.2", "androidx.test:rules:1.6.1")
}

val sshTestServer: Configuration by configurations.creating

dependencies {
    sshTestServer("org.apache.sshd:sshd-core:2.20.0")
    sshTestServer("org.apache.sshd:sshd-sftp:2.20.0")
    sshTestServer("org.jetbrains.kotlin:kotlin-stdlib:2.2.20")
    sshTestServer("org.bouncycastle:bcprov-jdk18on:1.86") // clés Ed25519 des clients
}

// Phase 13 : serveur SSH d'essai pour les essais instrumentés (tools/ssh/serveur-essai.sh), lancé sur le PC avec
// le classpath des tests JVM (MINA SSHD).
tasks.register<JavaExec>("runSshTestServer") {
    description = "Serveur SSH d'essai de la phase 13 (127.0.0.1:2222)"
    dependsOn("compileDebugUnitTestKotlin")
    classpath = files(layout.buildDirectory.dir("tmp/kotlin-classes/debugUnitTest")) + sshTestServer
    mainClass.set("com.mawena.fluluks.tools.SshTestServerKt")
    standardInput = System.`in`
}
