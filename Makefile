DIAGRAM_SRC = architecture.puml
DIAGRAM_SVG = $(DIAGRAM_SRC:.puml=.svg)
DIAGRAM_PNG = $(DIAGRAM_SRC:.puml=.png)

%.svg: %.puml
	plantuml --svg $<

%.png: %.puml
	plantuml --png $<

%.html: %.md
	pandoc -f gfm  --standalone -o "$@" --css style.css "$<" refresh.md

all: $(DIAGRAM_PNG)

clean:
	rm -f $(DIAGRAM_SVG) $(DIAGRAM_PNG) $(HTML_DOCS)
