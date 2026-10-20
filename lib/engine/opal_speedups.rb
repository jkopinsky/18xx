# frozen_string_literal: true

# backtick_javascript: true

# Browser-only speedups for the engine.
#
# In Opal (Ruby compiled to JavaScript), Enumerable#any?, #all?, #none?,
# #detect and #find_index stop early by throwing a JavaScript exception out of
# #each, and Array does not override them. Exceptions are slow, and the
# engine calls these methods constantly (every step's "what can this entity
# do?" check), so replaying a long game spent over 10% of its time throwing.
#
# These versions use a plain loop for the common case of an Array with a
# block, and fall back to the original for every other form. Nothing changes
# outside the browser.
if RUBY_ENGINE == 'opal'
  class Array
    def any?(pattern = undefined, &block)
      `if (self.length === 0) return false`
      pattern_given = `pattern !== undefined`
      return super if pattern_given || !block

      %x{
        for (var i = 0, n = self.length; i < n; i++) {
          if (Opal.truthy(Opal.yield1(block, self[i]))) return true;
        }
        return false;
      }
    end

    def all?(pattern = undefined, &block)
      pattern_given = `pattern !== undefined`
      return super if pattern_given || !block

      %x{
        for (var i = 0, n = self.length; i < n; i++) {
          if (!Opal.truthy(Opal.yield1(block, self[i]))) return false;
        }
        return true;
      }
    end

    def none?(pattern = undefined, &block)
      pattern_given = `pattern !== undefined`
      return super if pattern_given || !block

      %x{
        for (var i = 0, n = self.length; i < n; i++) {
          if (Opal.truthy(Opal.yield1(block, self[i]))) return false;
        }
        return true;
      }
    end

    def detect(ifnone = undefined, &block)
      ifnone_given = `ifnone !== undefined`
      return super if ifnone_given || !block

      %x{
        for (var i = 0, n = self.length; i < n; i++) {
          var value = self[i];
          if (Opal.truthy(Opal.yield1(block, value))) return value;
        }
        return nil;
      }
    end

    def find(ifnone = undefined, &block)
      ifnone_given = `ifnone !== undefined`
      return super if ifnone_given || !block

      detect(&block)
    end
  end
end
