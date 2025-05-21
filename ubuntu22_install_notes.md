# Install a old version of gcc to build qt4


Lets install gcc from source
```
mkdir -p ~/src
cd ~/src
wget http://ftp.gnu.org/gnu/gcc/gcc-7.5.0/gcc-7.5.0.tar.gz
tar -xzf gcc-7.5.0.tar.gz
cd gcc-7.5.0
./contrib/download_prerequisites

mkdir build && cd build
../configure --prefix=/local/gcc-7.5.0 --enable-languages=c,c++ --disable-multilib --disable-libsanitizer
make -j$(nproc)
make install
```

# Download and install a patched version of qt4

```
cd ~/src
git clone git@github.com:thesamprice/qt4.git

export PATH=/local/gcc-7.5.0/bin:$PATH
export CC=/local/gcc-7.5.0/bin/gcc
export CXX=/local/gcc-7.5.0/bin/g++

./configure -prefix /local/qt4.8.6 \
    -opensource -confirm-license -release -fast \
    -nomake examples -nomake demos \
    -no-phonon -no-webkit \
    -qt-zlib -qt-libjpeg -qt-libpng -no-openssl  -no-qt3support -no-webkit -fast -no-javascript-jit

make -j$(nproc)
make install
```

# Install cosmos4

```
cd ~/src
git clone git@github.com:thesamprice/COSMOS4.git
cd  COSMOS4
export PATH=/local/qt4.8.6/bin:$PATH
export LD_LIBRARY_PATH=/local/qt4.8.6/lib:$LD_LIBRARY_PATH
export CXXFLAGS="-DQT_NO_OPENSSL"
bundle install

cosmos demo demo
```