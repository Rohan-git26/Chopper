allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Some plugins (e.g. flutter_pcm_sound) hardcode an older compileSdk (33) than
// their transitive AndroidX dependencies require (34+). Force every Android
// subproject that hasn't evaluated yet (the plugins) to compile against a
// modern SDK. :app is already evaluated here and is set to 36 directly.
subprojects {
    if (!state.executed) {
        afterEvaluate {
            val androidExtension = extensions.findByName("android")
            if (androidExtension is com.android.build.gradle.BaseExtension) {
                androidExtension.compileSdkVersion(36)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
