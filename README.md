# SyphonVST
Realtime Hardware accelerated surface sharing in your very DAW via [Syphon](https://syphon.info/) (: <br>
_Right click the vst window to change the Syphon server. <br>_
<ins>Currently only compiled on and tested on Mojave 10.14.6 but might work on older MacOS?</ins>

Big shout out to [Tom Butterworth](http://kriss.cx/tom) and [Anton Marini](https://vade.info/) for creating this amazing technology!
<br>
<br>

__Compile VST:__

- Default: instrument (SyphonVSTi.vst) into standard VST folder <br>
`./build_vst.sh`

- Instrument version <br>
`./build_vst.sh --instrument`

- Effect version <br>
`./build_vst.sh --effect`

- Instrument into custom folder <br>
`./build_vst.sh --dest $HOME/Music/vst`

- Effect into custom folder <br>
`./build_vst.sh --effect --dest $HOME/Music/vst`

