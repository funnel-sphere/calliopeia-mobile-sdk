plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

group = "com.calliopeia"
version = "0.1.0"

android {
    namespace = "com.calliopeia.edgeaudio.contracts"
    compileSdk = 36

    defaultConfig { minSdk = 26 }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
