# Performs pruning or one-level promotion of Hash attributes (typically
# labeled "private") and deep joins of Hash objects. Works on Array objects
# containing Hash objects as well.
#
# The typical use case is to have a YAML file containing both public and
# private data, with all private data nested within "private" properties:
#
# my_data_collection = {
#   'name' => 'mbland', 'full_name' => 'Mike Bland',
#   'private' => {
#     'email' => 'michael.bland@gsa.gov', 'location' => 'DCA',
#    },
# }
#
# Contributed by the 18F team, part of the United States
# General Services Administration: https://18f.gsa.gov/
#
# Author: Mike Bland (michael.bland@gsa.gov)
module HashJoiner
  # Recursively strips information from +collection+ matching +key+.
  #
  # To strip all private data from the example collection in the module
  # comment:
  #   HashJoiner.remove_data my_data_collection, "private"
  # resulting in:
  #   {'name' => 'mbland', 'full_name' => 'Mike Bland'}
  #
  # +collection+:: Hash or Array from which to strip information
  # +key+:: key determining data to be stripped from +collection+
  def self.remove_data(collection, key)
    if collection.instance_of? ::Hash
      collection.delete key
      collection.each_value {|i| remove_data i, key}
    elsif collection.instance_of? ::Array
      collection.each {|i| remove_data i, key}
      collection.delete_if {|i| i.empty?}
    end
  end

  # Recursively promotes data within the +collection+ matching +key+ to the
  # same level as +key+ itself. After promotion, each +key+ reference will
  # be deleted.
  #
  # To promote private data within the example collection in the module
  # comment, rendering it at the same level as other, nonprivate data:
  #   HashJoiner.promote_data my_data_collection, "private" 
  # resulting in:
  #   {'name' => 'mbland', 'full_name' => 'Mike Bland',
  #    'email' => 'michael.bland@gsa.gov', 'location' => 'DCA'}
  #
  # +collection+:: Hash or Array from which to promote information
  # +key+:: key determining data to be promoted within +collection+
  def self.promote_data(collection, key)
    if collection.instance_of? ::Hash
      if collection.member? key
        data_to_promote = collection[key]
        collection.delete key
        deep_merge collection, data_to_promote
      end
      collection.each_value {|i| promote_data i, key}

    elsif collection.instance_of? ::Array
      collection.each do |i|
        # If the Array entry is a hash that contains only the target key,
        # then that key should map to an Array to be promoted.
        if i.instance_of? ::Hash and i.keys == [key]
          data_to_promote = i[key]
          i.delete key
          deep_merge collection, data_to_promote
        else
          promote_data i, key
        end
      end

      collection.delete_if {|i| i.empty?}
    end
  end

  # Raised by deep_merge() if lhs and rhs are of different types.
  class MergeError < ::Exception
  end

  # Performs a deep merge of Hash and Array structures. If the collections
  # are Hashes, Hash or Array members of +rhs+ will be deep-merged with
  # any existing members in +lhs+. If the collections are Arrays, the values
  # from +rhs+ will be appended to lhs.
  #
  # Raises MergeError if lhs and rhs are of different classes, or if they
  # are of classes other than Hash or Array.
  #
  # +lhs+:: merged data sink (left-hand side)
  # +rhs+:: merged data source (right-hand side)
  def self.deep_merge(lhs, rhs)
    mergeable_classes = [::Hash, ::Array]

    if lhs.class != rhs.class
      raise MergeError.new("LHS (#{lhs.class}): #{lhs}\n" +
        "RHS (#{rhs.class}): #{rhs}")
    elsif !mergeable_classes.include? lhs.class
      raise MergeError.new "Class not mergeable: #{lhs.class}"
    end

    if rhs.instance_of? ::Hash
      rhs.each do |key,value|
        if lhs.member? key and mergeable_classes.include? value.class
          deep_merge(lhs[key], value)
        else
          lhs[key] = value
        end
      end

    elsif rhs.instance_of? ::Array
      lhs.concat rhs
    end
  end

  # Raised by join_data() if an error is encountered.
  class JoinError < ::Exception
  end

  # Joins objects in +lhs[category]+ with data from +rhs[category]+. If the
  # object collections are of type Array of Hash, key_field will be used as
  # the primary key; otherwise key_field is ignored.
  #
  # Raises JoinError if an error is encountered.
  #
  # +category+:: determines member of +lhs+ to join with +rhs+
  # +key_field+:: if specified, primary key for Array of joined objects
  # +lhs+:: joined data sink of type Hash (left-hand side)
  # +rhs+:: joined data source of type Hash (right-hand side)
  def self.join_data(category, key_field, lhs, rhs)
    rhs_data = rhs[category]
    return unless rhs_data

    lhs_data = lhs[category]
    if !(lhs_data and [::Hash, ::Array].include? lhs_data.class)
      lhs[category] = rhs_data
    elsif lhs_data.instance_of? ::Hash
      self.deep_merge lhs_data, rhs_data
    else
      self.join_array_data key_field, lhs_data, rhs_data
    end
  end

  # Raises JoinError if +h+ is not a Hash, or if
  # +key_field+ is absent from any element of +lhs+ or +rhs+.
  def self.assert_is_hash_with_key(h, key, error_prefix)
    if !h.instance_of? ::Hash
      raise JoinError.new("#{error_prefix} is not a Hash: #{h}")
    elsif !h.member? key
      raise JoinError.new("#{error_prefix} missing \"#{key}\": #{h}")
    end
  end

  # Joins data in the +lhs+ Array with data from the +rhs+ Array based on
  # +key_field+. Both +lhs+ and +rhs+ should be of type Array of Hash.
  # Performs a deep_merge on matching objects; assigns values from +rhs+ to
  # +lhs+ if no corresponding object yet exists in lhs.
  #
  # Raises JoinError if either lhs or rhs is not an Array of Hash, or if
  # +key_field+ is absent from any element of +lhs+ or +rhs+.
  #
  # +key_field+:: primary key for joined objects
  # +lhs+:: joined data sink (left-hand side)
  # +rhs+:: joined data source (right-hand side)
  def self.join_array_data(key_field, lhs, rhs)
    unless lhs.instance_of? ::Array and rhs.instance_of? ::Array
      raise JoinError.new("Both lhs (#{lhs.class}) and " +
        "rhs (#{rhs.class}) must be an Array of Hash")
    end

    lhs_index = {}
    lhs.each do |i|
      self.assert_is_hash_with_key(i, key_field, "LHS element")
      lhs_index[i[key_field]] = i
    end

    rhs.each do |i|
      self.assert_is_hash_with_key(i, key_field, "RHS element")
      key = i[key_field]
      if lhs_index.member? key
        deep_merge lhs_index[key], i
      else
        lhs << i
      end
    end
  end
end
