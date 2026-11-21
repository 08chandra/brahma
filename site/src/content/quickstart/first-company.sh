# A git workspace, channels and an org from the software pack (six seats).
brahma company create Acme --goal "Build a todo app"

# Add one more agent: a designer on the haiku model.
brahma hire Acme designer --role designer --model haiku

# Post to the company channel as the owner.
brahma say Acme '#general' "@ceo please draft a plan and ask @cto for a stack"
