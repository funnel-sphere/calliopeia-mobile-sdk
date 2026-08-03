pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "calliopeia-mobile-sdk"
include(":audio-contracts", ":audio-capture")

project(":audio-contracts").name = "audio-contracts"
project(":audio-capture").name = "audio-capture"
