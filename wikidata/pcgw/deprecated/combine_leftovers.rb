# Combine separate leftovers files into one.
require 'json'

leftovers = JSON.load(File.read('leftovers.json'))
leftovers2 = JSON.load(File.read('leftovers2.json'))
leftovers3 = JSON.load(File.read('leftovers3.json'))

leftovers = (leftovers << leftovers2).flatten!
leftovers = (leftovers << leftovers3).flatten!
leftovers.uniq!

File.write('leftovers4.json', leftovers.to_json)
