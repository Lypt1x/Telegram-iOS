load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGDeletedMessagesStore",
    module_name = "SGDeletedMessagesStore",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Swiftgram/SGAppGroupIdentifier:SGAppGroupIdentifier",
        "//Swiftgram/SGLogging:SGLogging",
        "//submodules/sqlcipher:sqlcipher",
    ],
    visibility = [
        "//visibility:public",
    ],
)
