import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 读取签名配置(android/key.properties,已 gitignore)。缺失时回退 debug 签名,便于他人克隆构建。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "cc.zhiting.bili_merger"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "cc.zhiting.bili_merger"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // 只打 64 位:现代设备均为 arm64,不再适配 32 位(armeabi-v7a)
            abiFilters += listOf("arm64-v8a")
        }
    }

    // abiFilters 管不住 Flutter Gradle 插件自己塞进来的 libflutter.so / libapp.so,
    // 不加这段的话 APK 里会多出 armeabi-v7a 与 x86_64 两套引擎(约 32MB 未压缩),
    // 而它们没有配套的 libffmpeg.so,装上去也合并不了。这里直接从打包阶段剔除。
    packaging {
        jniLibs {
            excludes += listOf(
                "lib/armeabi-v7a/**",
                "lib/armeabi/**",
                "lib/x86/**",
                "lib/x86_64/**",
            )
        }
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // 有 key.properties 用正式签名,否则回退 debug(方便无密钥者克隆构建)
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }
}


flutter {
    source = "../.."
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
}
