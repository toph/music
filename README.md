# Overview

Code excerpted from Chapter 2 of my book, Practical Ruby Projects: Ideas for the Eclectic Programmer. It guides you through the construction of an environment for live coding music in Ruby (where you can modify the music as it is playing).

# Getting started

Begin with a `rvm install 2.1.10`. This is latest version of Ruby this code can run on due to the DL module finally being retired in favor of newer (better) FFIs starting in Ruby 2.2.

Confession: this code originally targeted Ruby 1.8, but I couldn't in good conscience ask anyone to review code that didn't at least run on Ruby 2.X, so I forward ported as far as I could for you.

Don't forget to `bundle install` to get the `midilib` gem.

# Running

On your Mac, download and run SimpleSynth from: http://notahat.com/simplesynth/

This will provide a MIDI destination to play our notes through.

Then you can start a live coding session with `ruby run.rb`. Edit the patterns in `live.rb` to change the music each time you save.

# Reviewing

All the interesting stuff is in `music.rb`.

# Caveats

This code was written for a book, so it isn't the same thing as production code.

For example, there isn't much in the way of comments, despite the presence of some things like dynamically linking into C libraries which ABSOLUTELY deserves documentation. In this case, that explanation is on the page, instead of in the code itself.

There's some recursion that would probably be avoided to prevent overflowing the stack on longer inputs.

It re-opens `Enumerable` to add a `#rest` method which would be a no-no as well.

The classes in `music.rb` aren't stored in one file per class as they should be, because music.rb is the concatonation of a series of code blocks in the book. In addition, the classes really all need to be namespaced together in a module.

Most importantly, it doesn't have any tests. My book does cover testing in Chapter 9 which focuses on parsing using parser combinators, but in the interest of keeping the text moving, I omit tests in the earlier chapters. That said, my own personal views on testing have become so strong that were I writing this code today, the code itself would have tests regardless of whether they ever appeared in the book. How else would I be sure it's right? =)

And last, the code was originally written in 2006. Many modern Ruby style conventions hadn't solidified then. It just didn't feel right not to address that, so I've added a Rubocop file and brought the code to compliance with that. But I'm willing to believe some little things have slipped through the cracks.
