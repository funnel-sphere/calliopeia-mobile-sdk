plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("maven-publish")
}

group = providers.gradleProperty("group").orElse("com.calliopeia").get()
version = providers.gradleProperty("version").orElse("0.1.0").get()

android {
    namespace = "com.calliopeia.edgeaudio.capture"
    compileSdk = 36

    defaultConfig { minSdk = 26 }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    publishing {
        singleVariant("release") { withSourcesJar() }
    }
}

dependencies {
    api(project(":audio-contracts"))
    implementation("androidx.annotation:annotation:1.10.0")
    testImplementation("junit:junit:4.13.2")
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                artifactId = project.name
                pom {
                    name.set("Calliopeia Audio Capture")
                    description.set("High-fidelity Android audio capture for Calliopeia.")
                    url.set("https://github.com/funnel-sphere/calliopeia-mobile-sdk")
                    licenses {
                        license {
                            name.set("Apache License 2.0")
                            url.set("https://www.apache.org/licenses/LICENSE-2.0")
                        }
                    }
                }
            }
        }
    }
}
