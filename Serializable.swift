import Foundation

/// Errors that can be thrown by the serialization system.
public enum CoderError : Error {
    case missingValue(forKey: String)
    case typeMistmatch(forKey: String)
    case unknownType(String)
    case invalidInput
}

fileprivate enum Primitive {
    case bytes([UInt8])
    case symbol(UInt64)
    case reference(UInt64)
    case list([Primitive])
    case table([(Primitive, Primitive)])
    case value(UInt64, [UInt64 : Primitive])
}

fileprivate extension UInt8 {
    static let bytesKey: UInt8 = 1
    static let symbolKey: UInt8 = 2
    static let valueKey: UInt8 = 3
    static let referenceKey: UInt8 = 4
    static let listKey: UInt8 = 5
    static let tableKey: UInt8 = 6
    static let versionKey: UInt8 = 128
    static let symbolTableKey: UInt8 = 129
    static let objectsKey: UInt8 = 130
    static let rootsKey: UInt8 = 131
}

// copy the raw bytes of a value
fileprivate func unsafeBytes<T>(for value: T) -> [UInt8] {
    var value = value
    return withUnsafeBytes(of: &value) { Array($0) }
}

// use raw bytes to recreate a value
fileprivate func unsafeValue<T>(from bytes: [UInt8]) -> T {
    return bytes.withUnsafeBytes { $0.baseAddress!.load(as: T.self) }
}

/// This class provides implementation support for both `Encoder` and `Decoder` and is not meant to be used on its own.
public class Coder {
    fileprivate var roots: [UInt64 : Primitive]
    fileprivate var objects: [Primitive]
    fileprivate var symbols: [String]
    fileprivate var symbolIndexes: [String : UInt64]

    fileprivate init() {
        roots = [:]
        objects = []
        symbols = []
        symbolIndexes = [:]
    }
    
    /// Creates an `Encoder` or `Decoder` instance from previously encoded data, or throws on error.
    public convenience init(from encodedData: Data) throws {
        self.init()

        let input = InputStream(data: encodedData)
        input.open()

        func readBytes(_ count: UInt64) throws -> [UInt8] {
            var buffer: [UInt8] = Array(repeating: 0, count: Int(count))
            guard input.read(&buffer, maxLength: buffer.count) == buffer.count else { throw CoderError.invalidInput }
            return buffer
        }

        func readByte() throws -> UInt8 {
            var byte: UInt8 = 0
            guard input.read(&byte, maxLength: 1) == 1 else { throw CoderError.invalidInput }
            return byte
        }
        
        func readNumber() throws -> UInt64 {
            let raw = try readBytes(UInt64(MemoryLayout<UInt64>.size))
            return unsafeValue(from: raw)
        }
        
        func readPrimitive() throws -> Primitive {
            switch try readByte() {
            case UInt8.bytesKey:
                return try .bytes(readBytes(readNumber()))
                
            case UInt8.symbolKey:
                return try .symbol(readNumber())

            case UInt8.referenceKey:
                return try .reference(readNumber())

            case UInt8.listKey:
                let values = try (0..<readNumber()).map { _ in
                    try readPrimitive()
                }
                return .list(values)
            
            case UInt8.tableKey:
                let values = try (0..<readNumber()).map { _ in
                    (try readPrimitive(), try readPrimitive())
                }
                return .table(values)
                
            case UInt8.valueKey:
                let typeIdentifier = try readNumber()
                var parts = [UInt64 : Primitive]()
                try (0..<readNumber()).forEach { _ in
                    try parts[readNumber()] = readPrimitive()
                }
                return .value(typeIdentifier, parts)
                
            default:
                throw CoderError.invalidInput
            }
        }
        
        // read the version header and make sure the version matches something we understand
        guard try readByte() == .versionKey else { throw CoderError.invalidInput }
        guard try readNumber() == 1 else { throw CoderError.invalidInput }
        
        // read the symbol table
        guard try readByte() == .symbolTableKey else { throw CoderError.invalidInput }
        try (0..<readNumber()).forEach { index in
            let identifier = try String(bytes: readBytes(readNumber()), encoding: .utf8)!
            symbols.append(identifier)
            symbolIndexes[identifier] = UInt64(index)
        }
        
        // read the objects
        guard try readByte() == .objectsKey else { throw CoderError.invalidInput }
        try (0..<readNumber()).forEach { _ in
            try objects.append(readPrimitive())
        }
        
        // read the root key/values
        guard try readByte() == .rootsKey else { throw CoderError.invalidInput }
        try (0..<readNumber()).forEach { _ in
            try roots[readNumber()] = readPrimitive()
        }
    }
    
    /// Saves the `Encoder` or `Decoder` state as a `Data` instance suitable for saving.
    public func makeData() -> Data {
        var output = Data()
        
        func writeByte(_ byte: UInt8) {
            output.append(byte)
        }
        
        func writeBytes(_ bytes: [UInt8]) {
            output.append(contentsOf: bytes)
        }
        
        func writeNumber(_ value: UInt64) {
            writeBytes(unsafeBytes(for: value))
        }
        
        func writePrimitive(_ primitive: Primitive) {
            switch primitive {
            case let .bytes(bytes):
                writeByte(.bytesKey)
                writeNumber(UInt64(bytes.count))
                writeBytes(bytes)
                
            case let .symbol(index):
                writeByte(.symbolKey)
                writeNumber(index)
                
            case let .reference(index):
                writeByte(.referenceKey)
                writeNumber(index)
                
            case let .list(list):
                writeByte(.listKey)
                writeNumber(UInt64(list.count))
                list.forEach(writePrimitive)
                
            case let .table(table):
                writeByte(.tableKey)
                writeNumber(UInt64(table.count))
                table.forEach {
                    writePrimitive($0)
                    writePrimitive($1)
                }
                
            case let .value(typeIdentifier, parts):
                writeByte(.valueKey)
                writeNumber(typeIdentifier)
                writeNumber(UInt64(parts.count))
                parts.forEach {
                    writeNumber($0)
                    writePrimitive($1)
                }
            }
        }
        
        // write the current version of the serialization format
        writeByte(.versionKey)
        writeNumber(1)
        
        // write all of the symbols as utf8
        writeByte(.symbolTableKey)
        writeNumber(UInt64(symbols.count))
        symbols.forEach {
            let bytes = Array($0.utf8)
            writeNumber(UInt64(bytes.count))
            writeBytes(bytes)
        }
        
        // write the objects
        writeByte(.objectsKey)
        writeNumber(UInt64(objects.count))
        objects.forEach(writePrimitive)
        
        // write the root key/values
        writeByte(.rootsKey)
        writeNumber(UInt64(roots.count))
        roots.forEach {
            writeNumber($0)
            writePrimitive($1)
        }
        
        return output
    }
}

/// The serialization encoder.
/// Use an instance of this class to encode values and objects and then call `makeData()` to generate an archive suitable for saving.
/// All `Serialization` types that will be encountered during encoding must have been registered with `enableSerialization()`.
public final class Encoder : Coder {
    private var typeIdentifierCache: [ObjectIdentifier : UInt64]
    private var encodedObjectIndexes: [ObjectIdentifier : UInt64]
    
    /// Creates a new, empty encoder.
    public override init() {
        self.typeIdentifierCache = [:]
        self.encodedObjectIndexes = [:]
        super.init()
    }
    
    /// Creates a new `Encoder` with the given value encoded as a root using an empty key.
    public convenience init(with value: Serializable) {
        self.init()
        encode(value)
    }
    
    // adds a new symbol if needed, returns the index of the symbol in the table.
    private func symbolIndex(_ identifier: String) -> UInt64 {
        if let existingIndex = symbolIndexes[identifier] {
            return existingIndex
        }
        
        // add it to the table
        let index = UInt64(symbols.count)
        symbols.append(identifier)
        symbolIndexes[identifier] = index
        return index
    }
    
    private func primitive(for rawValue: Any) -> Primitive {
        let type = type(of: rawValue)
        
        guard let value = rawValue as? Serializable else {
            fatalError("\(type) does not conform to Serializable")
        }
        
        // fetch the index number of the symbol that matches the type of the value
        func getTypeIdentifierIndex() -> UInt64 {
            let typeIdentifier = ObjectIdentifier(type)
            
            if let cachedIdentifierIndex = typeIdentifierCache[typeIdentifier] {
                return cachedIdentifierIndex
            }
            
            guard let name = serializationTypes.first(where: { ObjectIdentifier($0.1) == typeIdentifier })?.0 else {
                fatalError("\(type) conforms to Serializable but was not registered with \(type).enableSerialization()")
            }
            
            let typeIdentifierIndex = symbolIndex(name)
            typeIdentifierCache[typeIdentifier] = typeIdentifierIndex
            return typeIdentifierIndex
        }
        
        // actually encodes the value
        func makePrimitive() -> Primitive {
            let previous = roots
            roots = [:]
            
            value.encode(with: self)
            
            let encodedParts = roots
            roots = previous
            
            return .value(getTypeIdentifierIndex(), encodedParts)
        }
        
        // test if we're dealing with a reference type or not - if not, encode it and we're done!
        guard type is AnyClass else {
            return makePrimitive()
        }
        
        // since we have a reference type, we want to encode the instance only once and then reference it everywhere else
        // so we will need to check and update the objects table accordingly
        let id = ObjectIdentifier(value as AnyObject)
        
        // ensure we do not already have an entry in the objects table for this instance - if we do, then just return a reference
        if let index = encodedObjectIndexes[id] {
            return .reference(index)
        }
        
        let index = UInt64(objects.count)
        let reference = Primitive.reference(index)

        // this should prevent issues with circular references while encoding
        objects.append(reference)
        encodedObjectIndexes[id] = index
        
        // actually encode the object as a value and store it in the object table
        objects[Int(index)] = makePrimitive()

        // return a reference to the newly encoded object
        return reference
    }
    
    /// Encode any `Serializable` value. The type (and all types that type encodes) must first have been
    /// registered with `enableSerialization()` or else this will result in a fatal error. If the value is
    /// `nil`, nothing will be encoded and `key` is ignored.
    public func encode(_ optionalValue: Serializable?, forKey key: String = "") {
        guard let value = optionalValue else { return }
        precondition(roots.updateValue(primitive(for: value), forKey: symbolIndex(key)) == nil)
    }

    /// Encode raw bytes.
    public func encodeBytes(_ bytes: [UInt8], forKey key: String = "") {
        precondition(roots.updateValue(.bytes(Array(bytes)), forKey: symbolIndex(key)) == nil)
    }

    /// Encode the `String` directly as a symbol primitive which ensures only a single copy of the given string is stored in the archive.
    public func encodeSymbol(_ symbol: String, forKey key: String = "") {
        precondition(roots.updateValue(.symbol(symbolIndex(symbol)), forKey: symbolIndex(key)) == nil)
    }
    
    /// Encode any sequence as a raw "list". A list is expected to consist only of values that are `Serializable`. The list
    /// does not need to be flat - it can be arbitrarily complex or nested as long as all of the encoded types are registered.
    public func encodeList<T: Sequence>(_ list: T, forKey key: String = "") {
        let values = list.map(primitive(for:))
        precondition(roots.updateValue(.list(values), forKey: symbolIndex(key)) == nil)
    }

    /// Encode a sequence of pairs as a "table". The notes in `encodeList(_:forKey:)` apply here as well. This is useful
    /// for serializing data structures such as multimaps. Note that `Dictionary` already conforms to `Serializable` and uses
    /// a table as the underlying encoding mechanism, but you will need to register your specific type of Dictionary by using
    /// enableSerialization() on the type.
    public func encodeTable<T: Sequence, A, B>(_ table: T, forKey key: String = "") where T.Iterator.Element == (A, B) {
        let values = table.map { (primitive(for: $0), primitive(for: $1)) }
        precondition(roots.updateValue(.table(values), forKey: symbolIndex(key)) == nil)
    }
}

/// The serialization decoder.
/// Use an instance of this class initialized with `init(from:)` and then call the suitable `decode(forKey:)` functions.
/// Almost all functions in this class can throw errors since there are so many things that can go wrong.
public final class Decoder : Coder {
    private let decodedTypes: [UInt64 : Serializable.Type] = [:]
    private var decodedObjects: [UInt64 : Serializable] = [:]
    
    /// Creates a new `Decoder` directly from the current state of `encoder`.
    public convenience init(from encoder: Encoder) {
        self.init()
        roots = encoder.roots
        objects = encoder.objects
        symbols = encoder.symbols
        symbolIndexes = encoder.symbolIndexes
    }
    
    // ensures there is a primitive with the given name in the current roots structure
    private func primitive(forKey key: String) throws -> Primitive {
        guard let index = symbolIndexes[key], let result = roots[index] else { throw CoderError.missingValue(forKey: key) }
        return result
    }
    
    // safely ensures the symbol index is in range before attempting to access it
    private func symbol(at index: UInt64) throws -> String {
        guard index >= 0 && index < UInt64(symbols.count) else { throw CoderError.invalidInput }
        return symbols[Int(index)]
    }
    
    private func serializable(from primitive: Primitive, stashingValueInObjectTableAt objectIndex: UInt64? = nil) throws -> Serializable {
        if case let .reference(index) = primitive {
            if let value = decodedObjects[index] {
                return value
            }

            return try serializable(from: objects[Int(index)], stashingValueInObjectTableAt: index)
        }
        
        guard case let .value(index, parts) = primitive else {
            throw CoderError.invalidInput
        }
        
        func valueType() throws -> Serializable.Type {
            if let cachedType = decodedTypes[index] {
                return cachedType
            }

            let encodedSymbol = try symbol(at: index)
            guard let knownType = serializationTypes.first(where: { $0.0 == encodedSymbol })?.1 else {
                throw CoderError.unknownType(encodedSymbol)
            }
            
            return knownType
        }
        
        let previous = roots
        roots = parts
        
        let type = try valueType()
        var newValue = try type.init(with: self)

        if let idx = objectIndex {
            precondition(type is AnyClass)
            decodedObjects[idx] = newValue
        }
        
        if var restorable = newValue as? RestorableSerializable {
            try restorable.restored(with: self)
            newValue = restorable
        }
        
        roots = previous
        return newValue
    }
    
    /// Decode an optional 'Serializable' value of type `T` or return `nil` if `key` cannot be found.
    /// If there is a record for `key` and the type cannot be cast to `T`, then it will throw instead.
    public func decode<T: Serializable>(forKey key: String = "") throws -> T? {
        guard let codedValue = try? primitive(forKey: key) else { return nil }
        guard let value = try serializable(from: codedValue) as? T else { throw CoderError.typeMistmatch(forKey: key) }
        return value
    }
    
    /// Decode a non-optional `Serializable` value of type `T`.
    public func decode<T: Serializable>(forKey key: String = "") throws -> T {
        let codedValue = try primitive(forKey: key)
        guard let value = try serializable(from: codedValue) as? T else { throw CoderError.typeMistmatch(forKey: key) }
        return value
    }
    
    /// Decode an array of raw bytes.
    public func decodeBytes(forKey key: String = "") throws -> [UInt8] {
        let codedBytes = try primitive(forKey: key)
        guard case let .bytes(bytes) = codedBytes else { throw CoderError.typeMistmatch(forKey: key) }
        return bytes
    }

    /// Decode a `String` that was previously encoded as a symbol primitive.
    public func decodeSymbol(forKey key: String = "") throws -> String {
        let codedSymbol = try primitive(forKey: key)
        guard case let .symbol(index) = codedSymbol else { throw CoderError.typeMistmatch(forKey: key) }
        return try symbol(at: index)
    }

    /// Decode a list of `Serializable` values that were previously encoded using `Encoder`'s `encodeList(_:forKey:)` function.
    public func decodeList<T>(forKey key: String = "") throws -> [T] {
        let codedValue = try primitive(forKey: key)
        guard case let .list(parts) = codedValue else { throw CoderError.typeMistmatch(forKey: key) }
        return try parts.map({ try serializable(from: $0) as! T })
    }
    
    /// Decodes a table of `Serializable` values that was previously encoded using `Encoder`'s `encodeTable(_:forKey:)` function.
    public func decodeTable<A, B>(forKey key: String = "") throws -> [(A, B)] {
        let codedValue = try primitive(forKey: key)
        guard case let .table(parts) = codedValue else { throw CoderError.typeMistmatch(forKey: key) }
        return try parts.map { try (serializable(from: $0) as! A, serializable(from: $1) as! B) }
    }
}

/// Types that conform to `Serializable` can be encoded by an `Encoder` and decoded by a `Decoder`.
public protocol Serializable {
    /// Create a new instance of `Self` and restore state from the encoded values available in `coder`.
    /// If you are implementing this for a class, be sure to call super from subclasses or you'll have a bad time.
    init(with coder: Decoder) throws
    
    /// Encode the current state of `Self`'s instance by encoding values into `coder`.
    /// If you are implementing this for a class, be sure to call super from subclasses or you'll have a bad time.
    func encode(with coder: Encoder)
}

/// Types that conform to `RestorableSerializable` will have their `restored(with:)` function called after
/// the normal `init(with:)` initializer has returned. This can be used for restoring references that might be circular.
public protocol RestorableSerializable : Serializable {
    mutating func restored(with coder: Decoder) throws
}

/// A type that conforms to `AutomaticallyEncodedSerializable` will gain a default implementation of `encode(with:)`
/// which uses reflection to automatially encode all named properties it can find. Every found property must be of a type
/// that conforms to `Serializable` or else a fatal error will occur that will print out the offending type so you can fix it.
///
/// Unfortunately due to Swift's limitations, it is not really possible to automatically implement `init(with:)` and so
/// that is still your responsibily - but hey, it's better than having to implement both of the `Serializable` requirements
/// yourself!
public protocol AutomaticallyEncodedSerializable : Serializable {
}

public extension Serializable {
    /// This function is how you register a custom type for serialization. This must be called prior to attempting to encode
    /// or decode any instances of that type. Failure to do so will almost always cause a fatal error which will print out the
    /// type that was missing so it should be easy to fix.
    ///
    /// This is unfortunately necessary due to limitations of Swift's current implementation. I could not find any other way to
    /// do this that would work for non-Objective-C types since Swift has no way (that I know of) to instantiate an instance
    /// from a string of a type's name and there's no way to ask the runtime for a list of types that conform to a given protocol.
    /// If either of those problems could be solved, this requirement could probably be eliminated.
    ///
    /// Many standard common types such as `Int` and `UInt` (and the 8, 16, 32, and 64 variants) along with `Float`, `Double`,
    /// `Float80`, `String`, `Bool`, `Data`, and `Date` are all automatically registered as `Serializable`.
    ///
    /// Standard containers such as `Array`, `Dictionary`, and `Set` conform to `Serializable` out of the box, but they are not
    /// automatically registered because they are generic. You will need to register a number of such types prior to serialization
    /// depending on which combinations of containers and contained types you want to serialize. For example:
    ///
    ///     Array<Int>.enableSerialization()
    ///     Dictionary<String, Int>.enableSerialization()
    ///
    /// By default, the type's internal name (Module.TypeName) will be used as the type's internal identifier, but if you wish,
    /// you can specify any name you want using `identifier` as long as it is unique and that the name matches the same type when
    /// both encoding and decoding.
    static func enableSerialization(as identifier: String? = nil) {
        let record = serializationRecord(as: identifier)
        precondition(!serializationTypes.contains(where: { record.0 == $0.0 || record.1 == $0.1 }))
        serializationTypes.append(record)
    }

    /// This makes a clone (a deep copy) of the `Serializable` instance by doing an encode and then decode.
    /// Returns a new instance or `nil` if decoding failed for some reason.
    func makeClone() -> Self? {
        let encoder = Encoder()
        encoder.encode(self)
        
        let decoder = Decoder(from: encoder)
        return try? decoder.decode()
    }
}

/// Super clever way to detect when an `Any` instance is actually an `Optional` without using a `Mirror`.
/// This is used by `AutomaticallyEncodedSerializable`'s implementation of `encode(with:)`.
fileprivate protocol SerializingOptional {
    var serializable: Serializable? { get }
}

extension Optional : SerializingOptional {
    var serializable: Serializable? {
        if case let .some(value) = self {
            guard let unwrappedSerializable = value as? Serializable else {
                fatalError("\(type(of: value)) does not conform to Serializable")
            }
            return unwrappedSerializable
        } else {
            return nil
        }
    }
}

public extension AutomaticallyEncodedSerializable {
    func encode(with coder: Encoder) {
        var mirror: Mirror? = Mirror(reflecting: self)
        
        while mirror != nil {
            for (name, property) in mirror!.children where name != nil {
                if let optional = property as? SerializingOptional {
                    coder.encode(optional.serializable, forKey: name!)
                } else if let serializable = property as? Serializable {
                    coder.encode(serializable, forKey: name!)
                } else {
                    fatalError("\(type(of: self)) property '\(name!)' does not conform to Serializable")
                }
            }

            mirror = mirror?.superclassMirror
        }
    }
}

fileprivate extension Serializable {
    static func serializationRecord(as identifier: String? = nil) -> (String, Serializable.Type) {
        return (identifier ?? String(reflecting: self), self)
    }
}

extension Int : Serializable {
    public init(with coder: Decoder) throws { try self.init(truncatingBitPattern: Int64(littleEndian: unsafeValue(from: coder.decodeBytes()) as Int64)) }
    public func encode(with coder: Encoder) { coder.encodeBytes(unsafeBytes(for: Int64(self).littleEndian)) }
}

extension Int8 : Serializable {
    public init(with coder: Decoder) throws { try self.init(unsafeValue(from: coder.decodeBytes()) as Int8) }
    public func encode(with coder: Encoder) { coder.encodeBytes(unsafeBytes(for: self)) }
}

extension Int16 : Serializable {
    public init(with coder: Decoder) throws { try self.init(littleEndian: unsafeValue(from: coder.decodeBytes())) }
    public func encode(with coder: Encoder) { coder.encodeBytes(unsafeBytes(for: self.littleEndian)) }
}

extension Int32 : Serializable {
    public init(with coder: Decoder) throws { try self.init(littleEndian: unsafeValue(from: coder.decodeBytes())) }
    public func encode(with coder: Encoder) { coder.encodeBytes(unsafeBytes(for: self.littleEndian)) }
}

extension Int64 : Serializable {
    public init(with coder: Decoder) throws { try self.init(littleEndian: unsafeValue(from: coder.decodeBytes())) }
    public func encode(with coder: Encoder) { coder.encodeBytes(unsafeBytes(for: self.littleEndian)) }
}

extension UInt : Serializable {
    public init(with coder: Decoder) throws { try self.init(truncatingBitPattern: UInt64(littleEndian: unsafeValue(from: coder.decodeBytes()) as UInt64)) }
    public func encode(with coder: Encoder) { coder.encodeBytes(unsafeBytes(for: UInt64(self).littleEndian)) }
}

extension UInt8 : Serializable {
    public init(with coder: Decoder) throws { try self.init(unsafeValue(from: coder.decodeBytes()) as UInt8) }
    public func encode(with coder: Encoder) { coder.encodeBytes(unsafeBytes(for: self)) }
}

extension UInt16 : Serializable {
    public init(with coder: Decoder) throws { try self.init(littleEndian: unsafeValue(from: coder.decodeBytes())) }
    public func encode(with coder: Encoder) { coder.encodeBytes(unsafeBytes(for: self.littleEndian)) }
}

extension UInt32 : Serializable {
    public init(with coder: Decoder) throws { try self.init(littleEndian: unsafeValue(from: coder.decodeBytes())) }
    public func encode(with coder: Encoder) { coder.encodeBytes(unsafeBytes(for: self.littleEndian)) }
}

extension UInt64 : Serializable {
    public init(with coder: Decoder) throws { try self.init(littleEndian: unsafeValue(from: coder.decodeBytes())) }
    public func encode(with coder: Encoder) { coder.encodeBytes(unsafeBytes(for: self.littleEndian)) }
}

extension Float : Serializable {
    public init(with coder: Decoder) throws { try self.init(unsafeValue(from: coder.decodeBytes()) as Float) }
    public func encode(with coder: Encoder) { coder.encodeBytes(unsafeBytes(for: self)) }
}

extension Double : Serializable {
    public init(with coder: Decoder) throws { try self.init(unsafeValue(from: coder.decodeBytes()) as Double) }
    public func encode(with coder: Encoder) { coder.encodeBytes(unsafeBytes(for: self)) }
}

extension Float80 : Serializable {
    public init(with coder: Decoder) throws { try self.init(unsafeValue(from: coder.decodeBytes()) as Float80) }
    public func encode(with coder: Encoder) { coder.encodeBytes(unsafeBytes(for: self)) }
}

extension String : Serializable {
    public init(with coder: Decoder) throws { try self.init(coder.decodeSymbol())! }
    public func encode(with coder: Encoder) { coder.encodeSymbol(self) }
}

extension Bool : Serializable {
    public init(with coder: Decoder) throws { try self.init(unsafeValue(from: coder.decodeBytes()) as Bool) }
    public func encode(with coder: Encoder) { coder.encodeBytes(unsafeBytes(for: self)) }
}

extension Data : Serializable {
    public init(with coder: Decoder) throws { try self.init(bytes: coder.decodeBytes()) }
    public func encode(with coder: Encoder) { coder.encodeBytes(Array(self))}
}

extension Date : Serializable {
    public init(with coder: Decoder) throws { try self.init(timeIntervalSinceReferenceDate: coder.decode()) }
    public func encode(with coder: Encoder) { coder.encode(timeIntervalSinceReferenceDate) }
}

/// This protocol is handy for adding quick `Serializable` conformance for types that are sequences
/// and have (or can easily be given) a simple sequence initializer. It includes default implementations of
/// `init(with:)` and 'encode(with:)`. This is used by `Array` and `Set` to conform to 'Serializable' almost for free.
public protocol SerializableSequence : Serializable, Sequence {
    init<S : Sequence>(_ s: S) where S.Iterator.Element == Iterator.Element
}

public extension SerializableSequence {
    init(with coder: Decoder) throws {
        try self.init(coder.decodeList())
    }
    
    func encode(with coder: Encoder) {
        coder.encodeList(self)
    }
}

extension Array : SerializableSequence {}

extension Set : SerializableSequence {}

extension Dictionary : Serializable {
    public init(with coder: Decoder) throws {
        self.init()        
        for (key, value) in try coder.decodeTable() as [(Key, Value)] {
            precondition(updateValue(value, forKey: key) == nil)
        }
    }
    
    public func encode(with coder: Encoder) {
        coder.encodeTable(map({ ($0, $1) }))
    }
}

fileprivate var serializationTypes = [
    Bool.serializationRecord(),

    Int.serializationRecord(),
    Int8.serializationRecord(),
    Int16.serializationRecord(),
    Int32.serializationRecord(),
    Int64.serializationRecord(),
    
    UInt.serializationRecord(),
    UInt8.serializationRecord(),
    UInt16.serializationRecord(),
    UInt32.serializationRecord(),
    UInt64.serializationRecord(),
    
    Float.serializationRecord(),
    Double.serializationRecord(),
    Float80.serializationRecord(),
    
    String.serializationRecord(),
    
    Data.serializationRecord(),
    Date.serializationRecord(),
]
