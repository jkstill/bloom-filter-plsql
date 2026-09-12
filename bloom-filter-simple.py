import hashlib

class SimpleBloomFilter:
    def __init__(self, size=100, hash_count=3):
        self.size = size
        self.hash_count = hash_count
        self.bit_array = [0] * size

    def _indexes(self, item):
        # Generate multiple positions by salting the item string
        indexes = []
        for i in range(self.hash_count):
            salted = f"{item}-{i}".encode('utf-8')
            digest = hashlib.md5(salted).hexdigest()
            index = int(digest, 16) % self.size
            indexes.append(index)
        return indexes

    def add(self, item):
        for index in self._indexes(item):
            self.bit_array[index] = 1

    def __contains__(self, item):
        # Returns True if maybe in set, False if definitely not in set
        for index in self._indexes(item):
            if self.bit_array[index] == 0:
                return False
        return True

# Demonstration
bf = SimpleBloomFilter(size=50, hash_count=3)
bf.add("apple")
bf.add("banana")

print("apple:", "apple" in bf)    # True (possibly in set)
print("cherry:",  "cherry" in bf)   # False (definitely not in set)

