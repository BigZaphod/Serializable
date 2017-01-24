# Serializable
A Swift 3 implementation of an NSCoder-inspired serialization API

# Usage

Using Serializable is pretty easy - simply make your struct or class conform to the `Serializable` protocol which is very simple:

```Swift
protocol Serializable {
    init(with coder: Decoder) throws
    func encode(with coder: Encoder)
}
```

For example, let’s say we have the following structure:

```Swift
struct Dog {
    let name: String
    let isCute: Bool
    var isWaggingTail: Bool
}
```

First we conform it to `Serializable`:

```Swift
extension Dog : Serializable {
    init(with coder: Decoder) throws {
        name = try coder.decode(forKey: "name")
        isCute = try coder.decode(forKey: "isCute")
        isWaggingTail = try coder.decode(forKey: "isWaggingTail")
    }
    
    func encode(with coder: Encoder) {
        coder.encode(name, forKey: "name")
        coder.encode(isCute, forKey: "isCute")
        coder.encode(isWaggingTail, forKey: "isWaggingTail")
    }
}
```

Then we must tell the system about our new `Serializable` type (since Swift has no way that I know of to discover this dynamically). This only needs to be done - perhaps during app launch:

```Swift
Dog.enableSerialization()
```

Many common Swift and Foundation types such as `Int` and `UInt` (and the 8, 16, 32, and 64 variants) along with `Float`, `Double`, `Float80`, `String`, `Bool`, `Data`, and `Date` already conform to `Serializable` and are automatically registered.

Once you have your types conformed to `Serializable` and registered, it is a simple matter of making an `Encoder` and putting something into it:

```Swift
let myDog = Dog(name: "Fido", isCute: true, isWaggingTail: false)
let aCoder = Encoder()
aCoder.encode(myDog, forKey: "currentDog")
```

When you’re ready to save everything to a file, generate a `Data` object:

```Swift
let codedData = aCoder.makeData()
```

Decoding the serialized data is just as easy (of course you should catch the errors and not just ignore them like this simple sample):

```Swift
let aDecoder = try! Decoder(from: codedData)
let decodedDog: Dog = try! aDecoder.decode(forKey: "currentDog")
```

Tada!

If you have a collection to serialize such as:

```Swift
var bestFriends: Array<Dog> = [
    Dog(name: "Fido", isCute: true, isWaggingTail: false),
    Dog(name: "Ruff", isCute: true, isWaggingTail: true),
    Dog(name: "Rex", isCute: true, isWaggingTail: true)
]
```

You must also register an array of `Dog`s as a serializable type:

```Swift
Array<Dog>.enableSerialization()
```

`Array`, `Set` and `Dictionary` conform to `Serializable` out of the box - but they are not automatically registered since they’re generic. You simply must register any combination that you intend to serialize so the system knows what to do with them. If you accidentally forget to register a type, you’ll get a `fatalError()` noting the missing type when you try to test your serialization code.

There is also a `AutomaticallyEncodedSerializable` protocol which has a default implement of the `encode(with:)` function which uses Swift’s `Mirror` to automatically name and encode all the properties it finds. Using this, the example from above can be shortened to:

```Swift
extension Dog : AutomaticallyEncodedSerializable {
    init(with coder: Decoder) throws {
        name = try coder.decode(forKey: "name")
        isCute = try coder.decode(forKey: "isCute")
        isWaggingTail = try coder.decode(forKey: "isWaggingTail")
    }
}
```

The key names of the properties are taken from the property name. IMPORTANT: If using `AutomaticallyEncodedSerializable` with classes, then superclasses and subclasses effectively share a flat namespace for their properties - so any duplicate properties (even if private) will collide when encoding/decoding. This will almost certainly result in a fatalError.

Finally, there is a `RestorableSerializable` protocol which is simply:

```Swift
protocol RestorableSerializable : Serializable {
    mutating func restored(with coder: Decoder) throws
}
```

The `restored(with:)` function gets called after `init(with:)` has succeeded and after the object has been restored into the object table internally. This is most useful with classes where you might be to restore a circular reference to `self` or something like that.

# Notes

This is not yet well tested, of course, but it seems to work! Good luck!