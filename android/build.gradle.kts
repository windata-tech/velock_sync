allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// package:jni inherits Flutter's default NDK, which is corrupt in this
// development environment. Register before its script so this override runs
// before AGP creates CMake tasks; never modify the Pub cache.
gradle.beforeProject {
    if (path == ":jni") {
        afterEvaluate {
            val androidExtension = extensions.findByName("android")
            androidExtension?.javaClass?.methods
                ?.firstOrNull { it.name == "setNdkVersion" && it.parameterCount == 1 }
                ?.invoke(androidExtension, "28.0.13004108")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
