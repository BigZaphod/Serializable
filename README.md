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

Then we must tell the system about our new `Serializable` type (since Swift has no way that I know of to discover conforming types dynamically). This only needs to be done once - perhaps during app launch:

```Swift
Dog.enableSerialization()
```

Many basic Swift and Foundation types such as `Int` and `UInt` (and the 8, 16, 32, and 64 variants) along with `Float`, `Double`, `Float80`, `String`, `Bool`, `Data`, and `Date` already conform to `Serializable` and are automatically registered.

Once you have your types conformed to `Serializable` and registered, it is a simple matter of making an `Encoder` and encoding a value into it:

```Swift
let myDog = Dog(name: "Fido", isCute: true, isWaggingTail: false)
let aCoder = Encoder()
aCoder.encode(myDog, forKey: "currentDog")
```

When you’re ready to save everything you've encoded to a file or send it over the network, generate a `Data` object from the encoder:

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

...then you must also register an array of `Dog`s as a serializable type:

```Swift
Array<Dog>.enableSerialization()
```

`Array`, `Set` and `Dictionary` conform to `Serializable` out of the box - but they are not automatically registered since they’re generic. You must register any combination that you intend to serialize so the system knows what to do with them when it encounters them. If you accidentally forget to register a type, you’ll get a `fatalError()` noting the missing type when you try to test your serialization code - so they're easy to find and fix.

If you want to eliminate some boilerplate, use the `AutomaticallyEncodedSerializable` protocol which has a default implementation of `encode(with:)` that uses `Mirror` to automatically name and encode all of the properties it finds. Using this, the example from above can be shortened to:

```Swift
extension Dog : AutomaticallyEncodedSerializable {
    init(with coder: Decoder) throws {
        name = try coder.decode(forKey: "name")
        isCute = try coder.decode(forKey: "isCute")
        isWaggingTail = try coder.decode(forKey: "isWaggingTail")
    }
}
```

There is also the `RestorableSerializable` protocol:

```Swift
protocol RestorableSerializable : Serializable {
    mutating func restored(with coder: Decoder) throws
}
```

For types that conform to this protocol, the `restored(with:)` function is called after `init(with:)` has succeeded. This is most useful for class instances where you might need to restore a circular reference to `self` or something like that.

Finally, there is the `makeClone()` function implemented in an extension for `Serializable`. This grants any `Serializable` value the ability to make a deep copy by encoding and then decoding itself and returning the result. The `makeClone()` function is more efficient than encoding to data and then decoding since it copies the internal state of the encoder directly into the decoder - so if you want a deep copy, this is a decent way to get one.


# Notes

* The binary data format is pretty compact - it only stores string symbols once and, of course, only stores a single copy of a reference type instance. In my tests, it also seems to compress remarkably well.

* The binary format should be cross platform - it always writes integers in little endian format, and always stores strings and symbols as UTF-8. The `Int` and `UInt` types (which can be either 32 or 64 bit) are both always stored as 64 bit.

* If serializing classes, then superclasses and subclasses effectively share a flat namespace for the key names. Key name collisions when encoding or decoding will almost certainly result in a `fatalError()` due to an internal precondition explicitly designed to detect this sort of subtle bug before it becomes a problem for you later.

* This is not yet well tested, of course, but it seems to work! Good luck!