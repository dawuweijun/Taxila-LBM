### ====================================================================
###  Python-file
###     author:          Ethan T. Coon
###     filename:        solution_reader2.py
###     version:         
###     created:         25 January 2011
###       on:            10:53:33 MST
###     last modified:   22 August 2011
###       at:            11:52:20 MDT
###     URL:             http://www.ldeo.columbia.edu/~ecoon/
###     email:           ecoon _at_ lanl.gov
###  
### ====================================================================

import os
import numpy as np

class SolutionReader(object):
    def __init__( self, infile, prefix='' ):
        self._input_filename = infile
        self._prefix = prefix
        self._options = dict()

        fid = open(infile, 'r')
        for line in fid:
            if (not line.strip().startswith('#')):
                args = line.strip('\n').split(' ')
                if len(args) > 0 and args[0].startswith('-'+self._prefix):
                    if len(args) == 1:
                        self._options[args[0][len(self._prefix)+1:]] = True
                    else:
                        self._options[args[0][len(self._prefix)+1:]] = args[1]

        # discretization
        if self._options.has_key('discretization'):
            self._discretization = self._options['discretization'].lower()
        else:
            self._discretization = 'd3q19'

        # size
        if  self._discretization == 'd2q9':
            self._size = (int(self._options['NX']), int(self._options['NY']))
            self._dim = 2
            print 'got d2q9'
        elif self._discretization == 'd3q19':
            self._size = (int(self._options['NX']), int(self._options['NY']), int(self._options['NZ']))
            self._dim = 3
            print 'got d3q19'

        # ncomponents
        if self._options.has_key('ncomponents'):
            self._s = int(self._options['ncomponents'])
        else:
            self._s = 1

        lsize = list(self._size)
        lsize.reverse()
        self._size_r = tuple(lsize)

        # output file prefix
        if self._options.has_key('output_file_prefix'):
            self._file_prefix = self._options['output_file_prefix']
        else:
            self._file_prefix = 'test_solution/'

        self._vecs = dict()

    def loadVec( self, name ):
        import PetscBinaryRead

        print 'loading', self._file_prefix+name
        data = PetscBinaryRead.readBinaryFile(self._file_prefix+name)
        assert len(data) == 1
        vec = data[0]
        
        ndofs = len(vec)/np.array(self._size).prod()

        # convert to C/python ordering from fortran ordering
        if self._dim == 3:
            npvec = vec.reshape(self._size_r+(ndofs,)).transpose((2,1,0,3))[:]
        elif self._dim == 2:
            npvec = vec.reshape(self._size_r+(ndofs,)).transpose((1,0,2))[:]
        return npvec

    def loadSoln( self, number ):
        self._vecs['rho'] = self.loadVec('rho%03d.dat'%number)
        self._vecs['u'] = self.loadVec('u%03d.dat'%number)
        self._vecs['prs'] = self.loadVec('prs%03d.dat'%number)
        return

