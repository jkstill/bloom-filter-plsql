#!/usr/bin/env perl
use strict;
use warnings;

package BloomFilter;

use Digest::MD5 qw(md5_hex);

sub new {
    my ($class, %args) = @_;
    my $size = $args{size} || 20;
    
    my $self = {
        size       => $size,
        num_hashes => $args{num_hashes} || 3,
        bit_array  => [ (0) x $size ],
    };
    return bless $self, $class;
}

sub add {
    my ($self, $item) = @_;
    for my $i (0 .. $self->{num_hashes} - 1) {
		 # Gemini used a simple hash function here, which is not necessary as Digeest::MD5 is part of the base Perl distribution. So we can use it directly.
		 my $index = md5_hex("$item-$i");
		 $index = hex(substr($index, 0, 8)) % $self->{size};
		 $self->{bit_array}->[$index] = 1;
    }
}

sub contains {
    my ($self, $item) = @_;
    for my $i (0 .. $self->{num_hashes} - 1) {
		 my $index = md5_hex("$item-$i");
		 $index = hex(substr($index, 0, 8)) % $self->{size};
        return 0 if !$self->{bit_array}->[$index];
    }
    return 1;
}

# --- Demonstration ---
package main;

my $bf = BloomFilter->new(size => 20, num_hashes => 3);

# Add items
$bf->add("apple");
$bf->add("banana");

# Check membership
print "apple: "  . ($bf->contains("apple")  ? "Found" : "Not Found") . "\n"; # Found
print "cherry: " . ($bf->contains("cherry") ? "Found" : "Not Found") . "\n"; # Not Found

