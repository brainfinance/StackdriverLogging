# StackdriverLogging
A [SwiftLog](https://github.com/apple/swift-log)  `LogHandler` that logs GCP Stackdriver formatted JSON to a file.

For more information on Stackdriver structured logging, see: https://cloud.google.com/logging/docs/structured-logging and [LogEntry](https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry)

## Dependencies 
This Stackdriver `LogHandler` depends on [SwiftNIO](https://github.com/apple/swift-nio) which is used to create and save your new log entries in a non-blocking fashion. 

## How to install

### Swift Package Manager

```swift
.package(url: "https://github.com/Brainfinance/StackdriverLogging.git", from:"2.0.0")
```
In your target's dependencies add `"StackdriverLogging"` e.g. like this:
```swift
.target(name: "App", dependencies: ["StackdriverLogging"]),
```

## Bootstrapping 
A factory is used to instantiate `StackdriverLogHandler` instances. Before bootstrapping your swift-log `LoggingSystem`, you must first call the  `StackdriverLogHandler.Factory.prepare(_:_:)` with your logging destination.
The Logging destination can be either the standard output which would be whats expected under a gcp Cloud Run environment or a file of your choice. 
You are also responsible for gracefully shutting down the NIO dependencies used internally by the `StackdriverLogHandler.Factory` by calling its shutdown function, preferably in a defer statement right after preparing the factory.
```swift
try StackdriverLogHandler.Factory.prepare(for: .stdout)
defer {
    try! StackdriverLogHandler.Factory.syncShutdownGracefully()
}
let logLevel = Logger.Level.info
LoggingSystem.bootstrap { label -> LogHandler in
    var logger = StackdriverLogHandler.Factory.make()
    logger.logLevel = logLevel
    return logger
}
```
### Vapor 4
Here's a bootstrapping example for a standard Vapor 4 application.
```swift
import App
import Vapor

var env = try Environment.detect()
try StackdriverLogHandler.Factory.prepare(for: .stdout)
defer {
    try! StackdriverLogHandler.Factory.syncShutdownGracefully()
}
try LoggingSystem.bootstrap(from: &env) { (logLevel) -> (String) -> LogHandler in
    return { label -> LogHandler in
        var logger = StackdriverLogHandler.Factory.make()
        logger.logLevel = logLevel
        return logger
    }
}
let app = Application(env)
defer { app.shutdown() }
try configure(app)
try app.run()
```

## Logging JSON values using `Logger.MetadataValue`
To log metadata values as JSON, simply log all JSON values other than `String` as a `Logger.MetadataValue.stringConvertible` and, instead of the usual conversion of your value to a `String` in the log entry, it will keep the original JSON type of your values whenever possible.

For example:
```Swift
var logger = Logger(label: "Stackdriver")
logger[metadataKey: "jsonpayload-example-object"] = [
    "json-null": .stringConvertible(NSNull()),
    "json-bool": .stringConvertible(true),
    "json-integer": .stringConvertible(1),
    "json-float": .stringConvertible(1.5),
    "json-string": .string("Example"),
    "stackdriver-timestamp": .stringConvertible(Date()),
    "json-array-of-numbers": [.stringConvertible(1), .stringConvertible(5.8)],
    "json-object": [
        "key": "value"
    ]
]
logger.info("test")
```
Will log the non pretty-printed representation of:
```json
{  
   "sourceLocation":{  
      "function":"boot(_:)",
      "file":"\/Sources\/App\/boot.swift",
      "line":25
   },
   "jsonpayload-example-object":{  
      "json-bool":true,
      "json-float":1.5,
      "json-string":"Example",
      "json-object":{  
         "key":"value"
      },
      "json-null":null,
      "json-integer":1,
      "json-array-of-numbers":[  
         1,
         5.8
      ],
      "stackdriver-timestamp":"2019-07-15T21:21:02.451Z"
   },
   "message":"test",
   "severity":"INFO"
}
```

## Stackdriver logging agent + fluentd config 
You should preferably run the agent using the standard output destination `StackdriverLogHandler.Destination.stdout` which will get you up and running automatically under certain gcp environments such as Cloud Run.

If you prefer logging to a file, you can use a file destination `StackdriverLogHandler.Destination.stdout` in combination with the Stackdriver logging agent https://cloud.google.com/logging/docs/agent/installation and a matching json format
google-fluentd config (/etc/google-fluentd/config.d/example.conf) to automatically send your JSON logs to Stackdriver for you. 

Here's an example google-fluentd conf file that monitors a json based logfile and send new log entries to Stackdriver:
```
<source>
    @type tail
    # Format 'JSON' indicates the log is structured (JSON).
    format json
    # The path of the log file.
    path /var/log/example.log
    # The path of the position file that records where in the log file
    # we have processed already. This is useful when the agent
    # restarts.
    pos_file /var/lib/google-fluentd/pos/example-log.pos
    read_from_head true
    # The log tag for this log input.
    tag exampletag
</source>
```
