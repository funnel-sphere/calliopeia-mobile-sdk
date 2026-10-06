plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("maven-publish")
}
group = providers.gradleProperty("group").orElse("com.calliopeia").get()
version = providers.gradleProperty("version").orElse("0.4.0").get()
android {
    namespace = "com.calliopeia.auth"
    compileSdk = 36
    defaultConfig { minSdk = 26 }
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    publishing { singleVariant("release") { withSourcesJar() } }
}
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    api(project(":calliopeia-sdk"))
    implementation("com.amplifyframework:aws-auth-cognito:2.42.0")
    implementation("com.amplifyframework:core-kotlin:2.42.0")
}
afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                artifactId = project.name
                pom {
                    name.set("Calliopeia Android Auth")
                    description.set("Email OTP and session management for Calliopeia.")
                    url.set("https://github.com/funnel-sphere/calliopeia-mobile-sdk")
                    licenses { license { name.set("Apache License 2.0"); url.set("https://www.apache.org/licenses/LICENSE-2.0") } }
                }
            }
        }
    }
}
