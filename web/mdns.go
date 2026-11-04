package main

import (
	"log"
	"net"
	"strconv"
	"strings"

	"github.com/grandcat/zeroconf"
)

// advertise announces the web player on the local network as _mymusic-web._tcp, so the Mac
// (first-time setup) and iPhones (songs not on the phone) can find it without typing an address.
func advertise(s *server, listen string) {
	_, portStr, err := net.SplitHostPort(listen)
	if err != nil {
		log.Printf("mdns: can't parse %q: %v", listen, err)
		return
	}
	port, _ := strconv.Atoi(portStr)
	txt := []string{"v=1", "path=/"}
	if s.token != "" {
		txt = append(txt, "auth=1")
	}
	if s.smbURL != "" {
		txt = append(txt, "smb="+s.smbURL)
	}
	name := strings.TrimSuffix(s.name, ".local")
	srv, err := zeroconf.Register(name, "_mymusic-web._tcp", "local.", port, txt, nil)
	if err != nil {
		log.Printf("mdns: not announcing on the network: %v", err)
		return
	}
	_ = srv // runs for the life of the process
	log.Printf("mdns: announced as %q (_mymusic-web._tcp, port %d)", name, port)
}
