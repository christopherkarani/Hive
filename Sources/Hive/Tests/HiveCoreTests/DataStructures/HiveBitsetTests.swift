import Testing
@testable import HiveCore

@Suite("HiveBitset")
struct HiveBitsetTests {
    @Test("wordCount 0 produces empty bitset")
    func wordCountZeroProducesEmptyBitset() {
        let bitset = HiveBitset(wordCount: 0)
        #expect(bitset.isEmpty)
        // Out-of-bounds insert is a no-op
        var mutable = bitset
        mutable.insert(0)
        #expect(mutable.isEmpty)
        #expect(mutable.contains(0) == false)
    }

    @Test("insert out-of-bounds is a no-op")
    func insertOutOfBoundsIsNoOp() {
        var bitset = HiveBitset(bitCapacity: 64)
        bitset.insert(64)   // one past the end of a 1-word bitset
        bitset.insert(100)
        bitset.insert(-1)
        #expect(bitset.isEmpty)
    }

    @Test("contains out-of-bounds returns false")
    func containsOutOfBoundsReturnsFalse() {
        var bitset = HiveBitset(bitCapacity: 64)
        bitset.insert(0)
        #expect(bitset.contains(64) == false)
        #expect(bitset.contains(-1) == false)
    }

    @Test("bitCapacity 0 produces single-word bitset via init")
    func bitCapacityZeroProducesSingleWord() {
        // init(bitCapacity:) clamps to at least 1 word (64 bits)
        var bitset = HiveBitset(bitCapacity: 0)
        bitset.insert(0)
        #expect(bitset.contains(0))
    }


    @Test("insert/contains work across 64-bit word boundaries")
    func insertContainsAcrossWordBoundaries() {
        var bitset = HiveBitset(bitCapacity: 130)
        bitset.insert(0)
        bitset.insert(63)
        bitset.insert(64)
        bitset.insert(129)

        #expect(bitset.contains(0))
        #expect(bitset.contains(63))
        #expect(bitset.contains(64))
        #expect(bitset.contains(129))
        #expect(bitset.contains(65) == false)
    }

    @Test("equal bitsets compare equal for >64 node masks")
    func equalBitsetsCompareEqual() {
        var lhs = HiveBitset(bitCapacity: 70)
        var rhs = HiveBitset(bitCapacity: 70)
        for bit in [1, 5, 6, 63, 64, 69] {
            lhs.insert(bit)
            rhs.insert(bit)
        }
        #expect(lhs == rhs)
    }

    @Test("removeAll clears previously set bits")
    func removeAllClearsBits() {
        var bitset = HiveBitset(bitCapacity: 65)
        bitset.insert(0)
        bitset.insert(64)
        #expect(bitset.isEmpty == false)

        bitset.removeAll()
        #expect(bitset.isEmpty)
        #expect(bitset.contains(0) == false)
        #expect(bitset.contains(64) == false)
    }
}
